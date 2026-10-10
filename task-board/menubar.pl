#!/usr/bin/perl
# 菜单栏（menubar.js）的启动器：插件在会话启动 / 连上时调它，同一时间只留一个菜单栏。
#
#   perl menubar.pl start <menubar.js> <scan.pl> <缓存分钟数> <共享目录或空> <本机标签>
#   perl menubar.pl stop
#
# start：已经有一个同一份 menubar.js 在跑就什么都不做；在跑的是别的版本（插件升级了）就先停掉它。
#        新的菜单栏两次 fork + setsid 脱离会话（会话关了它也不跟着退），pid 写进 ~/.claude/task-board-menubar.pid。
# stop： 停掉在跑的菜单栏（设置项 menuBar 关掉时）。
use strict;
use warnings;
use POSIX ();

my $home = $ENV{HOME} // (getpwuid($<))[7];
my $pidPath = "$home/.claude/task-board-menubar.pid";

# 在跑的菜单栏：(pid, 命令行)；没有 = ()
sub running {
  open(my $fh, '<', $pidPath) or return ();
  my $pid = <$fh> // '';
  close $fh;
  $pid =~ s/\s+//g;
  return () unless $pid =~ /^\d+$/ && kill(0, $pid);
  my $cmd = `/bin/ps -p $pid -o command=` // '';
  chomp $cmd;
  return $cmd =~ /osascript .*menubar\.js/ ? ($pid, $cmd) : ();
}

sub stop_running {
  my ($pid) = running();
  return unless $pid;
  kill 'TERM', $pid;
  unlink $pidPath;
}

my $verb = shift @ARGV // '';
if ($verb eq 'stop') {
  stop_running();
  print "stopped\n";
  exit 0;
}
die "usage: menubar.pl start <menubar.js> <scan.pl> <ttl> <shared> <device> | stop\n" unless $verb eq 'start' && @ARGV >= 2;

my ($js, @rest) = @ARGV;
my ($pid, $cmd) = running();
if ($pid) {
  # 同一份脚本在跑：不动（命令行里含脚本的完整路径）
  if (index($cmd, $js) >= 0) { print "running\n"; exit 0 }
  stop_running();
}

# 两次 fork + setsid：菜单栏不属于这个会话，也不是谁的子进程
my $child = fork() // die "fork: $!\n";
if ($child) { waitpid($child, 0); print "started\n"; exit 0 }
POSIX::setsid();
exit 0 if fork();
open(STDIN, '<', '/dev/null');
open(STDOUT, '>', '/dev/null');
open(STDERR, '>', '/dev/null');
if (open(my $fh, '>', $pidPath)) { print $fh "$$\n"; close $fh }
exec('/usr/bin/osascript', '-l', 'JavaScript', $js, @rest) or exit 1;
