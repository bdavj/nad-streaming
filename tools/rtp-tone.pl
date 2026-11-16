#!/usr/bin/perl
# rtp-tone.pl: play a test tone through BluOS's AirPlay slot, without shairport-sync.
# The minimal example of the plugin protocol + dspout RTP path (see docs/PROTOCOL.md):
#   plugin -> core (airplay_req01): P1 S0 L1, F "airplay_pcm01:pcm/44100/16/2/<id>", metadata JSON
#   core -> plugin (airplay_cmd01): F <id>, O <id> <latency>, N 01 <u32 pos_ms> <u32 realtime_ms%1e9> <u32 mode>
#   audio: RTP PT96 datagrams to /var/data/pcm_rtp_socket01 (20-byte little-endian header + S16LE PCM),
#          timestamp = stream position (us) at which the packet should play.
# It takes over airplay_cmd01, so the real plugin stops receiving commands until it is restarted.
# usage (on the device):  AMP=10362 perl rtp-tone.pl [seconds]     # AMP 3277 = -20 dBFS (default), 10362 = -10 dBFS
# Logs to /var/data/airplay/probe2.log. TURN THE AMP DOWN FIRST.
use strict; use warnings;
use Socket; use IO::Handle; use Time::HiRes qw(time sleep);

my $dir  = '/var/data/airplay';
my $req  = "$dir/airplay_req01";
my $cmdp = "$dir/airplay_cmd01";
my $rtpp = '/var/data/pcm_rtp_socket01';
my $SID  = 7;
my $SECS = $ARGV[0] // 8;
open(my $L, '>>', "$dir/probe2.log") or die; $L->autoflush(1);
sub lg { my $t = time; printf $L "%s.%03d %s\n", scalar(localtime $t) =~ s/^\w+ \w+ +\d+ //r, ($t - int $t) * 1000, "@_" }

socket(my $tx, PF_UNIX, SOCK_DGRAM, 0) or die;
sub tell_core { my ($m, $why) = @_; my $r = send($tx, $m, 0, sockaddr_un($req));
    lg("SEND $why len=" . length($m) . ' -> ' . (defined $r ? 'ok' : "ERR $!")) }

unlink $cmdp;
socket(my $rx, PF_UNIX, SOCK_DGRAM, 0) or die;
bind($rx, sockaddr_un($cmdp)) or die "bind cmd: $!";
chmod 0777, $cmdp;
socket(my $rtp, PF_UNIX, SOCK_DGRAM, 0) or die;

my ($npos, $nreal);   # last N: stream position (ns) at realtime (ns)
my $opened = 0;
sub poll_core {
    my ($wait) = @_;
    my $rin = ''; vec($rin, fileno($rx), 1) = 1;
    while (select(my $r = $rin, undef, undef, $wait)) {
        $wait = 0;
        recv($rx, my $b, 65536, 0);
        my $t = substr($b, 0, 1);
        if ($t eq 'N') {
            # binary form (AirPlay/Spotify endpoints): 'N' 01 u32be pos_ms, u32be realtime_ms%1e9, u32be extra
            my ($pm, $rm, $x) = unpack('NNN', substr($b, 2, 12));
            my $now_ms = time * 1000; my $base = $now_ms - ($now_ms % 1e9);
            my $real_ms = $base + $rm; $real_ms -= 1e9 if $real_ms > $now_ms + 5e8;
            our $live;
            my $is_live = $x >= 1000;                                           # x = capture latency us once hw clock runs
            if (!$is_live && $live) { next }                                    # stale pre-roll N after switch
            if ($is_live && !$live) { $live = 1; undef $nreal;                  # clock switched to hardware
                my $old = defined $npos ? sprintf('%.1f', pos_us() / 1000) : '?';
                lg("CLOCK SWITCH: x=$x new pos_ms=$pm at real_ms%1e9=$rm (old clock said $old ms)") }
            if (defined $nreal && $real_ms * 1e6 <= $nreal) { next }            # stale / out of order
            ($npos, $nreal) = ($pm * 1e6, $real_ms * 1e6);
            lg("RECV N pos_ms=$pm real_ms%1e9=$rm x=$x hex=" . unpack('H*', $b));
        } else {
            (my $a = substr($b, 0, 120)) =~ s/[^\x20-\x7e]/./g;
            lg("RECV $t len=" . length($b) . ' hex=' . unpack('H*', substr($b, 0, 40)) . " [$a]");
            $opened = 1 if $t eq 'O' || $t eq 'F';
        }
    }
}
# current stream position in us, extrapolated from the last N
sub pos_us { return undef unless defined $npos; ($npos + (time * 1e9 - $nreal)) / 1000 }

tell_core("P\x01", 'P 01'); poll_core(0.3);
tell_core("S\x00", 'S 00'); poll_core(0.3);
tell_core("L\x01", 'L 01'); poll_core(2.5);   # let core finish stopping the previous source
my $gotF = 0;
for my $try (1 .. 3) {
    tell_core("Fairplay_pcm01:pcm/44100/16/2/$SID", "F announce #$try");
    my $tf = time; while (time - $tf < 2.5) { poll_core(0.2); last if defined $npos || $opened }
    last if defined $npos || $opened;
}
tell_core('{"isPlaying":true,"isStream":false,"title":"RTP probe","album":"sovi-airplay test","artist":"Claude",'
        . '"cover":"","rate":44100,"duration_ms":' . ($SECS * 1000) . ',"elapsed_ms":0,"ts":0}', 'metadata JSON');

my $t0 = time;
poll_core(0.2) while time - $t0 < 5 && !defined $npos;
if (!defined $npos) { lg("no N from core within 5 s, giving up"); tell_core("P\x00", 'P 00'); exit 0 }

# 441 Hz: exactly 100 samples per cycle, 441 cycles per second -> 1 s buffer loops seamlessly
my $A = $ENV{AMP} || 3277;
my $tone = join '', map { my $v = int($A * sin(2 * 3.14159265358979 * $_ / 100)); pack('s<s<', $v, $v) } 0 .. 44099;
$tone .= substr($tone, 0, 4 * 2000);   # wrap room
my $FR = 363;
my $LEAD = ($ENV{LEAD} || 250) * 1000;
my $start = int(pos_us() + $LEAD);
lg("first packet scheduled at stream pos " . sprintf('%.3f', $start / 1e6) . " s (now " . sprintf('%.3f', pos_us() / 1e6) . ")");
my ($seq, $n, $sent, $err) = (0, 0, 0, 0);
my ($maxgap, $last, $minlead, $maxlead) = (0, undef, 1e9, -1e9);
my $total = 44100 * $SECS;
while ($n < $total) {
    my $ts = $start + int($n * 1e6 / 44100);
    poll_core(0);
    my $ahead = $ts - pos_us();
    if ($ahead > $LEAD) { sleep(($ahead - $LEAD) / 1e6 > 0.004 ? 0.004 : ($ahead - $LEAD) / 1e6); next }
    $minlead = $ahead if $ahead < $minlead; $maxlead = $ahead if $ahead > $maxlead;
    my $hdr = pack('CCvVvvCCvV', 0x80, 0xe0, $seq & 0xffff, $ts & 0xffffffff, 882, $FR, 16, 0, 2, 0);
    defined(send($rtp, $hdr . substr($tone, ($n % 44100) * 4, $FR * 4), 0, sockaddr_un($rtpp))) ? $sent++ : ($err++ < 3 && lg("rtp send: $!"));
    my $now = time; if (defined $last && $now - $last > $maxgap) { $maxgap = $now - $last } $last = $now;
    $seq++; $n += $FR;
}
lg(sprintf("pacing: max gap between sends %.1f ms, lead min %.0f ms max %.0f ms", $maxgap * 1000, $minlead / 1000, $maxlead / 1000));
lg("sent $sent packets ($err errors), " . sprintf('%.1f', time - $t0) . " s");
poll_core(1.0);
tell_core('G', 'G (paused)'); poll_core(0.5);
tell_core("P\x00", 'P 00'); poll_core(1.0);
lg("probe2 finished");
