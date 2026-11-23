#!/usr/bin/perl
# 菜单栏（menubar.js）和浮窗（floatwin.js）的启动器：插件在会话启动 / 连上时调它，同一个脚本同一时间只留一个在跑。
#
#   perl menubar.pl start <menubar.js 或 floatwin.js> <scan.pl> <缓存分钟数> <共享目录或空> <本机标签>
#   perl menubar.pl stop [menubar|floatwin]
#
# start：已经有一个同一份脚本在跑（或者另一个目录里内容一模一样的那份）就什么都不做；在跑的是别的版本（插件升级了）就先停掉它。
#        新的进程两次 fork + setsid 脱离会话（会话关了它也不跟着退），pid 写进 ~/.claude/task-board-<脚本名>.pid。
# stop： 停掉在跑的那个（设置项 menuBar / floatWindow 关掉时）；不写名字 = menubar。
#
# 浮窗多两个标记文件（都在 ~/.claude 下）：
#   task-board-floatwin.hidden  用户点了浮窗的关闭按钮（或菜单栏里取消了勾）：start 不拉起，打印 hidden；
#                               菜单栏里再勾上（删掉标记后 start），或者设置项关掉再打开（stop 会删掉它）就回来
#   task-board-floatwin.off     设置项 floatWindow 关着（stop 时写、start 时删）：菜单栏里就不列浮窗那一项
use strict;
use warnings;
use POSIX ();
use File::Compare ();

my $home = $ENV{HOME} // (getpwuid($<))[7];
# 管的是哪个脚本（menubar / floatwin）：start 时从脚本文件名来，stop 时从参数来
my $name = 'menubar';
my $pidPath;
sub named {
  $name = $_[0];
  $pidPath = "$home/.claude/task-board-$name.pid";
}
named($name);
my $hiddenPath = "$home/.claude/task-board-floatwin.hidden";
my $offPath = "$home/.claude/task-board-floatwin.off";
sub touch { if (open(my $fh, '>', $_[0])) { close $fh } }

# 在跑的那个：(pid, 命令行)；没有 = ()
sub running {
  open(my $fh, '<', $pidPath) or return ();
  my $pid = <$fh> // '';
  close $fh;
  $pid =~ s/\s+//g;
  return () unless $pid =~ /^\d+$/ && kill(0, $pid);
  my $cmd = `/bin/ps -p $pid -o command=` // '';
  chomp $cmd;
  return $cmd =~ /osascript .*\Q$name\E\.js/ ? ($pid, $cmd) : ();
}

sub stop_running {
  my ($pid) = running();
  return unless $pid;
  kill 'TERM', $pid;
  unlink $pidPath;
}

my $verb = shift @ARGV // '';
if ($verb eq 'stop') {
  named($ARGV[0]) if @ARGV && $ARGV[0] =~ /^(?:menubar|floatwin)$/;
  stop_running();
  if ($name eq 'floatwin') { unlink $hiddenPath; touch($offPath) }
  print "stopped\n";
  exit 0;
}
die "usage: menubar.pl start <menubar.js|floatwin.js> <scan.pl> <ttl> <shared> <device> | stop [menubar|floatwin]\n" unless $verb eq 'start' && @ARGV >= 2;

my ($js, @rest) = @ARGV;
named($1) if $js =~ m{(?:^|/)(menubar|floatwin)\.js$};
if ($name eq 'floatwin') {
  unlink $offPath;
  # 用户把浮窗隐藏了：不拉起（在跑的它自己 2 秒内会退出）
  if (-e $hiddenPath) { print "hidden\n"; exit 0 }
}
my ($pid, $cmd) = running();
if ($pid) {
  # 同一份脚本在跑：不动（命令行里含脚本的完整路径）
  if (index($cmd, $js) >= 0) { print "running\n"; exit 0 }
  # 在跑的是另一个目录里一模一样的脚本（同一个版本装在两处）：也不动，不然每开一个会话它都要重启一次、浮窗闪一下
  if ($cmd =~ m{ -l JavaScript (.*?/\Q$name\E\.js)(?: |$)} && -e $1 && File::Compare::compare($1, $js) == 0) { print "running\n"; exit 0 }
  stop_running();
}

# 两次 fork + setsid：它不属于这个会话，也不是谁的子进程
my $child = fork() // die "fork: $!\n";
if ($child) { waitpid($child, 0); print "started\n"; exit 0 }
POSIX::setsid();
exit 0 if fork();
open(STDIN, '<', '/dev/null');
open(STDOUT, '>', '/dev/null');
open(STDERR, '>', '/dev/null');
if (open(my $fh, '>', $pidPath)) { print $fh "$$\n"; close $fh }
exec('/usr/bin/osascript', '-l', 'JavaScript', $js, @rest) or exit 1;
