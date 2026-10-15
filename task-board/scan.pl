#!/usr/bin/perl
# 增量扫描 ~/.claude/projects 下各会话的 transcript，每轮输出一行 JSON。
# macOS 版：每台 Mac 自带 /usr/bin/perl（5.34，含 JSON::PP），不用另装任何东西。
# 和 Windows 版 scan.ps1 逐段对应，输出格式完全一样。
#
#   perl scan.pl [--once] [--hours 24] [--max 12] [--interval-ms 3000] [--shared DIR] [--device NAME] [--latest FILE] [--home DIR] [--app DIR]
#   --shared DIR  跨设备共享目录（同步盘里）：每 10 秒把本机快照写成 DIR/<device>.json，每轮读目录里其他电脑的快照附在 remote 里
#   --device NAME 本机标签（卡片上的灰色小标签，也是共享目录里的文件名；空 = Mac）
#   --latest FILE 每一轮把输出的那一行（含 remote）原子地写进 FILE：菜单栏（menubar.js）读它，不用等 10 秒一次的共用快照
#   --lead-only   只当主扫描：本机已经有主扫描在跑就输出一行 {"follow":"<主扫描的输出文件>"}（有 --latest 也写进 FILE）后退出，
#                 调用方自己去读那个文件，不再挂一个进程转发
#   --home / --app 只在测试时用：换掉 ~ 和桌面应用的会话目录。
use strict;
use warnings;
use utf8;
use JSON::PP;
use Encode qw(decode);
use Time::Local qw(timegm);
use Time::HiRes qw(time sleep);
use File::Basename qw(basename dirname);
use File::Spec;
use Fcntl qw(:flock);
use POSIX ();

my ($once, $hours, $max, $intervalMs) = (0, 24, 12, 3000);
my $leadOnly = 0;
my $home = $ENV{HOME} // (getpwuid($<))[7];
my $appRoot;
my ($shared, $device, $latest) = ('', '', '');
while (@ARGV) {
  my $a = shift @ARGV;
  if ($a eq '--once') { $once = 1 }
  elsif ($a eq '--lead-only') { $leadOnly = 1 }
  elsif ($a eq '--hours') { $hours = 0 + shift @ARGV }
  elsif ($a eq '--max') { $max = 0 + shift @ARGV }
  elsif ($a eq '--interval-ms') { $intervalMs = 0 + shift @ARGV }
  elsif ($a eq '--home') { $home = shift @ARGV }
  elsif ($a eq '--app') { $appRoot = shift @ARGV }
  elsif ($a eq '--shared') { $shared = shift @ARGV // '' }
  elsif ($a eq '--device') { $device = shift @ARGV // '' }
  elsif ($a eq '--latest') { $latest = shift @ARGV // '' }
}
my $root = "$home/.claude/projects";
# 全局开关（所有会话共用）：任务板上按一下就改这个文件，各会话的扫描进程每轮都重读
my $prefsPath = "$home/.claude/task-board-prefs.json";
# 账号用量（5 小时 / 每周额度）：哪个会话拿到新读数就写这里，扫描进程原样转给所有会话
my $usagePath = "$home/.claude/task-board-usage.json";
# iPhone Live 推送器的配置：本机有它，任务板上才画「iPhone Live」开关（开关存在 prefs 的 liveActivity，推送器读同一个文件）
my $livePath = "$home/.claude/task-board-live.json";
# iCloud 上传有没有卡住（2026-10-14 卡了 4 个多小时才有人发现：别的电脑和手机一直看不到 Mac 的会话）：
# 共享目录在 iCloud 里时，每 5 分钟往共享目录放一个探针小文件，90 秒后看 brctl status 的待上传清单里它还在不在；
# 还在 = 卡住了，输出 sharedWarn 让任务板红字提示，之后每分钟再看，传上去了就清掉。
# 探针不用 .json 后缀（.json 会被当成电脑快照读）。测试用 TASK_BOARD_BRCTL 换一个假的 brctl、TASK_BOARD_UPLOAD_WAIT_SEC 改等待
my $BRCTL = $ENV{TASK_BOARD_BRCTL} // '/usr/bin/brctl';
my $UPLOAD_WAIT_SEC = $ENV{TASK_BOARD_UPLOAD_WAIT_SEC} // 90;
my ($uploadProbeAt, $uploadLastCheck, $uploadStuckSince, $uploadPending) = (0, 0, 0, 0);
# “在等我决定”的标记：每个会话一个文件（文件名 = 会话 id，内容 = 标记时间毫秒，空 = 没在等）
my $inputDir = "$home/.claude/task-board-input";
mkdir $inputDir unless -d $inputDir;
# 最近一轮的输出（所有会话共用）：新开的会话先显示它，不用等自己的扫描进程读完所有 transcript
my $snapPath = "$home/.claude/task-board-snapshot.json";
my $lastSnap = 0;
# 桌面应用的会话元数据：cliSessionId（= transcript 文件名）→ 应用里的会话编号、标题、是否已归档
$appRoot //= "$home/Library/Application Support/Claude/claude-code-sessions";
# 跨设备共享：本机标签（用户每台机器各设一个，默认 Mac）和系统；共享目录开头的 ~ = 用户主目录
my $os = 'mac';
$device = 'Mac' if $device eq '';
$shared =~ s{^~(?=/|$)}{$home};
if ($shared ne '' && !-d $shared) {
  require File::Path;
  eval { File::Path::make_path($shared) };
  $shared = '' unless -d $shared;   # 建不出来（同步盘没装）就当没开
}

unlink "$shared/$device-upload-check.txt" if $shared ne '' && $device ne '';
# 同一台电脑只让一个扫描进程真扫：App 让最近打开过的会话都在后台挂着，每个会话各起一个扫描进程，
# 十几个一起扫既费 CPU，又一起写共享目录里的快照（iCloud 会记成冲突，对面电脑看到的就成了 Mac(1).json）。
# 拿到锁的是主扫描，每轮把输出写进 $leadPath；其他的只转发这一份。主扫描所在的会话关了，锁随之释放，谁先拿到谁接手。
# 参数不同（共享目录、本机标签、范围）的扫描输出不一样，各用各的锁。
my $leadSig = unpack('%32C*', join("\0", $hours, $max, $shared, $device));
my $lockPath = "$home/.claude/task-board-scan-$leadSig.lock";
my $leadPath = "$home/.claude/task-board-scan-$leadSig.json";
my $lockFh;
my $isLead = $once;   # --once（测试）不排队
my $LEAD_MAX_SEC = 10;   # 主扫描的输出超过这么久没更新就不转发（它正在交接或卡住了）

# 共享目录里的快照超过这么久没更新 = 那台电脑离线，不显示（和插件里的 SNAP_MAX_SEC 一致）
my $SHARED_MAX_MS = 10 * 60 * 1000;

# 输出走管道给插件读：非 ASCII 一律转成 \uXXXX（和 Windows 版一致，插件那边 JSON.parse 还原）
my $json = JSON::PP->new->ascii->canonical(0);
my $jsonIn = JSON::PP->new->utf8;   # 解析 transcript 里的整行（字节串）

my %files;   # path -> 增量状态
my $rxId = qr/"id":"(msg_[^"]+)"/;
my $rxUsage = qr/"usage":\{"input_tokens":(\d+),"cache_creation_input_tokens":(\d+),"cache_read_input_tokens":(\d+),"output_tokens":(\d+)/;
my $rxKind = qr/"type":"(assistant|user)","uuid"/;
my $rxStop = qr/"stop_reason":"([a-z_]+)"/;
my $rxTitle = qr/"customTitle":"((?:[^"\\]|\\.)*)"/;
my $rxPrompt = qr/"lastPrompt":"((?:[^"\\]|\\.)*)"/;
my $rxCwd = qr/"cwd":"((?:[^"\\]|\\.)*)"/;
my $rxTs = qr/"timestamp":"([^"]+)"/;
my $rxTaskUpd = qr/"name":"TaskUpdate","input":\{[^}]*?"taskId":"(\d+)"[^}]*?"status":"([a-z_]+)"/;
my $rxModel = qr/"model":"(claude-[^"]+)"/;
my $rxTool = qr/"type":"tool_use","id":"[^"]*","name":"([^"]+)"/;
my $rxEffort = qr/"effort":"([a-z]+)"/;
# 派到后台的活（后台命令、后台子代理、Workflow）：工具结果里的编号；完成通知里带同一个编号和结束状态。Monitor 只是盯着，不算
my $rxBgCmd = qr/"backgroundTaskId":"([A-Za-z0-9_-]+)"/;
my $rxBgAsync = qr/"(?:agentId|taskId)":"([A-Za-z0-9_-]+)"/;
my $rxBgDone = qr{<task-id>([A-Za-z0-9_-]+)</task-id>(?:(?!</task-notification>).)*?<status>(?:completed|failed|killed|stopped)</status>};
# 要我答了才继续的工具：提问、计划审批、“开新会话 / 在这里做”卡片（start_session 的 offer）
my $rxWaitTool = qr/"type":"tool_use","id":"([^"]+)","name":"(AskUserQuestion|ExitPlanMode|mcp__ccd_session__start_session)"/;
# 后台的活和“在等我”的工具超过这么久还没结果就不算了（会话被关掉、App 重启时不会有完成通知）
my $PENDING_MAX_SEC = 6 * 3600;

# JSON 字符串里的转义（\n、\"、\uXXXX）还原成文字；坏的原样返回
sub unesc {
  my ($s) = @_;
  my $v = eval { $jsonIn->decode("\"$s\"") };
  return defined $v ? $v : $s;
}

# "2026-10-08T13:37:00.123Z" → 秒（带小数，UTC）；认不出返回 undef
sub ts {
  my ($s) = @_;
  my $v;
  if ($s =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?(Z|[+-]\d\d:?\d\d)?$/) {
    my ($y, $mo, $d, $h, $mi, $sec, $frac, $tz) = ($1, $2, $3, $4, $5, $6, $7, $8);
    $v = eval { timegm($sec, $mi, $h, $d, $mo - 1, $y) };
    if (defined $v) {
      $v += "0.$frac" if defined $frac;
      if (defined $tz && $tz ne 'Z' && $tz =~ /^([+-])(\d\d):?(\d\d)$/) {
        my $off = ($2 * 3600 + $3 * 60) * ($1 eq '-' ? -1 : 1);
        $v -= $off;
      }
    }
  }
  return $v;
}

sub new_file_state {
  return {
    offset => 0, msgs => {}, tin => 0, tcw => 0, tcr => 0, tout => 0,
    title => '', prompt => '', cwd => '', kind => '', stop => '', todos => undef, tasks => {}, taskOrder => [], taskN => 0,
    lastReq => undef,    # 最后一次 API 请求的时间（UTC 秒），用来算提示缓存还剩多久
    # 步骤计时：任务 / todo 变成 in_progress 和 completed 的时间；todoT 按 todo 内容记
    todoT => {}, lastDone => undef,
    turnAt => undef,     # 这一轮用户提问的时间（没有任务清单时的总耗时从这里算）
    bg => {},            # 还在后台跑的活：编号 -> 派出去的时间（UTC 秒）
    waitId => '', waitAt => undef,   # 还没答的提问 / 计划审批 / 开新会话卡片：工具调用 id 和时间
    model => '', tool => '', firstTs => undef, lastTs => undef, effort => '', calls => 0,   # 子代理行用
  };
}

# 一个步骤变状态时记时间：in_progress 记开始，completed 记结束（没见过开始就用上一步结束的时间）
sub mark_step {
  my ($st, $t, $s, $ts) = @_;
  return unless defined $ts;
  if ($s eq 'in_progress' && !defined $t->{a}) { $t->{a} = $ts }
  elsif ($s eq 'completed' && !defined $t->{e}) {
    if (!defined $t->{a}) {
      $t->{a} = (defined $st->{lastDone} && defined $t->{c} && $st->{lastDone} >= $t->{c}) ? $st->{lastDone} : $t->{c};
    }
    $t->{e} = $ts; $st->{lastDone} = $ts;
  }
}

# 桌面版自己的任务清单（mcp__ccd_turn__update_plan）放进同一份 tasks：
#   items = 整份清单（同名的步骤留着原来的计时）；advance = 当前这步做完、下一个没开始的开始；done / start = 按 1 起的序号
sub apply_plan {
  my ($st, $in, $ts) = @_;
  return unless ref $in eq 'HASH';
  my $set = sub { my ($t, $s) = @_; $t->{s} = $s; mark_step($st, $t, $s, $ts) };
  if (ref $in->{items} eq 'ARRAY' && @{ $in->{items} }) {
    my %prev = map { ($st->{tasks}{$_}{t} => $st->{tasks}{$_}) } grep { $st->{tasks}{$_} } @{ $st->{taskOrder} };
    $st->{tasks} = {}; $st->{taskOrder} = [];
    my $n = 0;
    for my $it (@{ $in->{items} }) {
      next unless ref $it eq 'HASH';
      $n++;
      my $title = '' . ($it->{content} // '');
      my $t = $prev{$title} // { s => 'pending', t => $title, c => $ts, a => undef, e => undef };
      $set->($t, '' . ($it->{status} // 'pending'));
      $st->{tasks}{$n} = $t; push @{ $st->{taskOrder} }, "$n";
    }
    $st->{taskN} = $n;
    return;
  }
  my @list = map { $st->{tasks}{$_} } grep { $st->{tasks}{$_} } @{ $st->{taskOrder} };
  if ($in->{advance}) {
    my $cur = -1;
    for my $i (0 .. $#list) { if ($list[$i]{s} eq 'in_progress') { $cur = $i; last } }
    $set->($list[$cur], 'completed') if $cur >= 0;
    for my $i ($cur + 1 .. $#list) { if ($list[$i]{s} eq 'pending') { $set->($list[$i], 'in_progress'); last } }
  }
  if (ref $in->{done} eq 'ARRAY') {
    for my $d (@{ $in->{done} }) { my $i = int($d // 0) - 1; $set->($list[$i], 'completed') if $i >= 0 && $i <= $#list }
  }
  if ($in->{start}) { my $i = int($in->{start}) - 1; $set->($list[$i], 'in_progress') if $i >= 0 && $i <= $#list }
}

sub read_new {
  my ($path, $st) = @_;
  open(my $fh, '<:raw', $path) or return;
  my $size = -s $fh;
  $st->{offset} = 0 if $size < $st->{offset};   # 文件被重写
  my $len = $size - $st->{offset};
  if ($len <= 0) { close $fh; return }
  seek($fh, $st->{offset}, 0);
  my $buf = '';
  my $read = 0;
  while ($read < $len) {
    my $n = read($fh, $buf, $len - $read, $read);
    last if !defined $n || $n <= 0;
    $read += $n;
  }
  close $fh;
  my $last = rindex($buf, "\n");
  return if $last < 0;                            # 还没有完整的一行
  $st->{offset} += $last + 1;
  my $text = substr($buf, 0, $last);

  for my $line (split /\n/, $text) {
    next if length($line) < 2;
    my $lts;
    if ($line =~ $rxTs) { $lts = ts($1) }
    if (defined $lts) { $st->{firstTs} //= $lts; $st->{lastTs} = $lts }
    # 用户亲手发的提问 = 新一轮开始（工具结果、系统附带的消息没有这个标记）
    if (defined $lts && index($line, '"origin":{"kind":"human"}') >= 0) {
      $st->{turnAt} = $lts;
      # 新一轮已经开始：上一轮的 end_turn 不再代表“做完了”
      $st->{kind} = 'user'; $st->{stop} = '';
      $st->{waitId} = '';   # 我发了话 = 上一轮问我的已经答了
    }
    # 派到后台：Bash 的 backgroundTaskId，子代理 / Workflow 的 async_launched（只看 toolUseResult 里没转义的字段）
    my $tr = index($line, '"toolUseResult":{');
    if ($tr >= 0) {
      my $rest = substr($line, $tr);
      my $bid;
      if ($rest =~ $rxBgCmd) { $bid = $1 }
      elsif (index($rest, '"status":"async_launched"') >= 0 && $rest =~ $rxBgAsync) { $bid = $1 }
      $st->{bg}{$bid} = defined $lts ? $lts : time if defined $bid;
    }
    if (%{ $st->{bg} } && index($line, '<task-id>') >= 0) {
      delete $st->{bg}{$1} while $line =~ /$rxBgDone/g;
    }
    $st->{waitId} = '' if $st->{waitId} ne '' && index($line, "\"tool_use_id\":\"$st->{waitId}\"") >= 0;
    if ($line =~ $rxKind) {
      $st->{kind} = $1;
      if ($st->{kind} eq 'assistant') {
        if ($line =~ $rxModel) { $st->{model} = $1 }
        my @tools = ($line =~ /$rxTool/g);
        if (@tools) { $st->{tool} = $tools[-1]; $st->{calls} += scalar @tools }
        if ($line =~ $rxWaitTool && ($2 ne 'mcp__ccd_session__start_session' || index($line, '"initiation":"offer"') >= 0)) {
          $st->{waitId} = $1; $st->{waitAt} = $lts;
        }
        if ($line =~ $rxEffort) { $st->{effort} = $1 }
        $st->{stop} = ($line =~ $rxStop) ? $1 : '';
        if (index($line, '"usage"') >= 0 && $line =~ $rxUsage) {
          my @v = (0 + $1, 0 + $2, 0 + $3, 0 + $4);
          if ($line =~ $rxId) {
            my $id = $1;
            if (my $old = $st->{msgs}{$id}) {
              $st->{tin} -= $old->[0]; $st->{tcw} -= $old->[1]; $st->{tcr} -= $old->[2]; $st->{tout} -= $old->[3];
            }
            $st->{msgs}{$id} = \@v;
            $st->{tin} += $v[0]; $st->{tcw} += $v[1]; $st->{tcr} += $v[2]; $st->{tout} += $v[3];
            $st->{lastReq} = $lts if defined $lts;
          }
        }
        if (index($line, '"name":"TodoWrite"') >= 0) {
          my $o = eval { $jsonIn->decode($line) };
          my $content = ($o && ref $o->{message} eq 'HASH' && ref $o->{message}{content} eq 'ARRAY') ? $o->{message}{content} : [];
          for my $c (@$content) {
            next unless ref $c eq 'HASH' && ($c->{name} // '') eq 'TodoWrite';
            my $todos = (ref $c->{input} eq 'HASH' && ref $c->{input}{todos} eq 'ARRAY') ? $c->{input}{todos} : [];
            $st->{todos} = [@$todos];
            for my $td (@$todos) {
              next unless ref $td eq 'HASH';
              my $key = '' . ($td->{content} // '');
              $st->{todoT}{$key} //= { c => $lts, a => undef, e => undef };
              mark_step($st, $st->{todoT}{$key}, '' . ($td->{status} // ''), $lts);
            }
          }
        }
        if (index($line, '"name":"TaskCreate"') >= 0) {
          my $o = eval { $jsonIn->decode($line) };
          my $content = ($o && ref $o->{message} eq 'HASH' && ref $o->{message}{content} eq 'ARRAY') ? $o->{message}{content} : [];
          for my $c (@$content) {
            next unless ref $c eq 'HASH' && ($c->{name} // '') eq 'TaskCreate';
            # 上一份清单已经全部做完：这是一份新清单，旧的完成项不再计入（编号照旧往下数）
            if (@{ $st->{taskOrder} } && !grep { $st->{tasks}{$_}{s} ne 'completed' } @{ $st->{taskOrder} }) {
              $st->{tasks} = {}; $st->{taskOrder} = [];
            }
            $st->{taskN}++;
            my $subject = (ref $c->{input} eq 'HASH') ? ('' . ($c->{input}{subject} // '')) : '';
            $st->{tasks}{ $st->{taskN} } = { s => 'pending', t => $subject, c => $lts, a => undef, e => undef };
            push @{ $st->{taskOrder} }, '' . $st->{taskN};
          }
        }
        # 桌面版的任务清单；wrap_up 收尾时把正在做的那步勾掉
        if (index($line, '"name":"mcp__ccd_turn__update_plan"') >= 0 || index($line, '"name":"mcp__ccd_turn__wrap_up"') >= 0) {
          my $o = eval { $jsonIn->decode($line) };
          my $content = ($o && ref $o->{message} eq 'HASH' && ref $o->{message}{content} eq 'ARRAY') ? $o->{message}{content} : [];
          for my $c (@$content) {
            next unless ref $c eq 'HASH';
            my $nm = $c->{name} // '';
            if ($nm eq 'mcp__ccd_turn__update_plan') { apply_plan($st, $c->{input}, $lts) }
            elsif ($nm eq 'mcp__ccd_turn__wrap_up') {
              for my $k (@{ $st->{taskOrder} }) {
                my $t = $st->{tasks}{$k} or next;
                if ($t->{s} eq 'in_progress') { $t->{s} = 'completed'; mark_step($st, $t, 'completed', $lts) }
              }
            }
          }
        }
        while ($line =~ /$rxTaskUpd/g) {
          my ($id, $s2) = ($1, $2);
          next unless exists $st->{tasks}{$id};
          if ($s2 eq 'deleted') {
            delete $st->{tasks}{$id};
            $st->{taskOrder} = [grep { $_ ne $id } @{ $st->{taskOrder} }];
          } else {
            $st->{tasks}{$id}{s} = $s2; mark_step($st, $st->{tasks}{$id}, $s2, $lts);
          }
        }
      }
      if ($st->{cwd} eq '' && $line =~ $rxCwd) { $st->{cwd} = unesc($1) }
      next;
    }
    if (index($line, '"custom-title"') >= 0) { if ($line =~ $rxTitle) { $st->{title} = unesc($1) } }
    elsif (index($line, '"last-prompt"') >= 0) { if ($line =~ $rxPrompt) { $st->{prompt} = unesc($1) } }
  }
}

my %meta;
my $rxLocal = qr/"sessionId":"(local_[^"]+)"/;
my $rxCli = qr/"cliSessionId":"([^"]+)"/;
my $rxArch = qr/"isArchived":(true|false)/;
my $rxAppTitle = qr/"title":"((?:[^"\\]|\\.)*)"/;
# 应用重启后同一个会话会换一个新的 transcript，旧的 id 记在 priorCliSessionIds 里
my $rxPrior = qr/"priorCliSessionIds":\[([^\]]*)\]/;
# Remote Control 的会话编号（session_…）：别的电脑点这张卡时用它打开；开关过几次会有几个，最后一个是现在的
my $rxBridge = qr/"bridgeSessionIds":\[([^\]]*)\]/;

my %prior;
sub find_files {
  my ($dir, $re, $out, $depth) = @_;
  return if $depth > 6;
  opendir(my $dh, $dir) or return;
  for my $name (readdir $dh) {
    next if $name eq '.' || $name eq '..';
    my $p = "$dir/$name";
    if (-d $p) { find_files($p, $re, $out, $depth + 1) }
    elsif ($name =~ $re && -f $p) { push @$out, $p }
  }
  closedir $dh;
}

sub slurp {
  my ($p) = @_;
  open(my $fh, '<:raw', $p) or return undef;
  local $/;
  my $t = <$fh>;
  close $fh;
  return $t;
}

sub get_desktop_map {
  my %map;
  %prior = ();
  my @list;
  find_files($appRoot, qr/^local_.*\.json$/, \@list, 0) if -d $appRoot;
  for my $f (@list) {
    my $mtime = (stat $f)[9] // 0;
    my $c = $meta{$f};
    if (!$c || $c->{mtime} != $mtime) {
      my $txt = slurp($f) // '';
      # 每个捕获都先落到自己的变量（$1 是别名，放进列表里会被下一次匹配改掉）
      my ($local) = $txt =~ $rxLocal;
      my ($cli) = $txt =~ $rxCli;
      my ($arch) = $txt =~ $rxArch;
      my ($title) = $txt =~ $rxAppTitle;
      my ($priorList) = $txt =~ $rxPrior;
      my ($bridgeList) = $txt =~ $rxBridge;
      my @bridge = defined $bridgeList ? $bridgeList =~ /"((?:cse|session)_[A-Za-z0-9_-]+)"/g : ();
      $c = {
        mtime => $mtime,
        local => $local // '',
        cli => $cli // '',
        archived => (defined $arch && $arch eq 'true') ? 1 : 0,
        title => defined $title ? unesc($title) : '',
        prior => defined $priorList ? [ $priorList =~ /"([^"]+)"/g ] : [],
        bridge => @bridge ? $bridge[-1] : '',
      };
      $meta{$f} = $c;
    }
    $map{ $c->{cli} } = $c if $c->{cli} ne '';
    for my $old (@{ $c->{prior} }) { $prior{$old} = 1 if $old ne $c->{cli} }
  }
  return \%map;
}

sub get_st {
  my ($path) = @_;
  $files{$path} //= new_file_state();
  my $st = $files{$path};
  eval { read_new($path, $st) };
  return $st;
}

sub mtime_of { my ($p) = @_; my @s = stat($p); return @s ? $s[9] : 0 }

sub num { my ($v) = @_; return defined $v ? 0 + $v : undef }
sub str { my ($v) = @_; return defined $v ? '' . $v : '' }

# 共享目录（同步盘）里原地写，不换名：换名在 iCloud 看来是删掉旧文件再建一个新的，对面容易生出冲突副本。
# 读的一方偶尔读到半个文件，会因为不是完整的 JSON 跳过这一轮。
sub write_in_place {
  my ($text, $dest) = @_;
  open(my $fh, '>:raw', $dest) or return;
  print $fh $text;
  close $fh;
}

# 先写临时文件再整个换上（rename 是原子的），读的一方不会读到半个文件；几个会话同时写，谁后换上算谁的
sub swap_in {
  my ($text, $dest) = @_;
  my $tmp = "$dest.$$.tmp";
  open(my $fh, '>:raw', $tmp) or return;
  print $fh $text;
  close $fh;
  rename($tmp, $dest) or unlink $tmp;
}

# 主扫描的一轮：扫所有 transcript，输出一行
sub scan_round {
  my $now = time();
  my $cut = $now - $hours * 3600;
  my $desk = get_desktop_map();
  # 侧边栏里已归档的会话不显示；被同一会话的新 transcript 接替的旧 transcript 也不显示
  my @main;
  if (opendir(my $dh, $root)) {
    for my $d (readdir $dh) {
      next if $d eq '.' || $d eq '..';
      my $dir = "$root/$d";
      next unless -d $dir;
      opendir(my $dh2, $dir) or next;
      for my $name (readdir $dh2) {
        next unless $name =~ /^(.+)\.jsonl$/;
        my $id = $1;
        my $p = "$dir/$name";
        my $m = mtime_of($p);
        next unless -f $p && $m > $cut;
        next if $desk->{$id} && $desk->{$id}{archived};
        next if $prior{$id};
        push @main, [$p, $m, $id, $dir];
      }
      closedir $dh2;
    }
    closedir $dh;
  }
  @main = sort { $b->[1] <=> $a->[1] } @main;
  splice(@main, $max) if @main > $max;

  my @out;
  for my $entry (@main) {
    my ($path, $fileM, $id, $dirName) = @$entry;
    my $row = eval {
      my $st = get_st($path);
      my $mtime = $fileM;
      # 最后一条带时间的消息（主会话和子代理里最新的）：App 往 transcript 末尾补写的后台信息没有时间，不算
      my $msgT = $st->{lastTs};
      # 子代理 transcript：<session>/subagents/*.jsonl
      my %sub = (tin => 0, tcw => 0, tcr => 0, tout => 0, n => 0, active => 0);
      my @subRows;
      my $subDir = "$dirName/$id/subagents";
      if (-d $subDir && opendir(my $sdh, $subDir)) {
        for my $sname (sort readdir $sdh) {
          next unless $sname =~ /\.jsonl$/;
          my $sf = "$subDir/$sname";
          next unless -f $sf;
          my $ss = get_st($sf);
          my $sm = mtime_of($sf);
          $sub{tin} += $ss->{tin}; $sub{tcw} += $ss->{tcw}; $sub{tcr} += $ss->{tcr}; $sub{tout} += $ss->{tout}; $sub{n}++;
          # 跑完的子代理最后一步是 end_turn，或交回结果的 SubagentHandback 调用
          my $isActive = (($now - $sm) < 60 && $ss->{stop} ne 'end_turn' && $ss->{tool} ne 'SubagentHandback') ? 1 : 0;
          $sub{active}++ if $isActive;
          $mtime = $sm if $sm > $mtime;
          $msgT = $ss->{lastTs} if defined $ss->{lastTs} && (!defined $msgT || $ss->{lastTs} > $msgT);
          # 子代理明细行：正在跑的，和这一轮里跑完的（名字、类型来自旁边的 .meta.json）
          if ($isActive || (defined $st->{turnAt} && defined $ss->{lastTs} && $ss->{lastTs} >= $st->{turnAt})) {
            # .meta.json 可能比 transcript 晚一点写出来：没读到就下一轮再读
            if (!defined $ss->{agentType}) {
              $ss->{agentType} = ''; $ss->{desc} = '';
              (my $mf = $sf) =~ s/\.jsonl$/.meta.json/;
              if (-f $mf) {
                my $mj = eval { $jsonIn->decode(slurp($mf) // '') };
                if ($mj && ref $mj eq 'HASH') { $ss->{agentType} = str($mj->{agentType}); $ss->{desc} = str($mj->{description}) }
              }
            }
            my $from = $ss->{firstTs};
            my $to = $isActive ? $now : $ss->{lastTs};
            push @subRows, {
              name => $ss->{agentType}, desc => $ss->{desc}, model => $ss->{model}, tool => ($isActive ? $ss->{tool} : ''),
              effort => $ss->{effort}, calls => 0 + $ss->{calls},
              sec => (defined $from && defined $to) ? int($to - $from) : 0, active => $isActive,
              at => defined $from ? $from : 0,
            };
          }
        }
        closedir $sdh;
      }
      # 正在跑的在前，各自按开始时间；最多 30 行（at 先留着，下面要用它找是哪一步派出去的）
      @subRows = sort { ($b->{active} <=> $a->{active}) || ($a->{at} <=> $b->{at}) } @subRows;
      splice(@subRows, 30) if @subRows > 30;
      my $age = $now - $mtime;
      my $msgAge = defined $msgT ? $now - $msgT : $age;
      # 主会话的缓存只被主 transcript 里的请求续期（子代理用自己的缓存前缀）
      my $cacheAge = defined $st->{lastReq} ? int($now - $st->{lastReq}) : -1;

      # 状态：根据最后一条消息和文件多久没动
      my $status;
      if ($sub{active} > 0) { $status = 'running' }
      elsif ($st->{kind} eq 'assistant' && $st->{stop} eq 'end_turn') { $status = 'done' }
      elsif ($age < 90 && $msgAge < 90) { $status = 'running' }
      elsif ($st->{kind} eq 'assistant' && $st->{stop} eq 'tool_use') { $status = 'waiting' }
      else { $status = 'idle' }
      # 派到后台的活还没收到完成通知：这一轮虽然结束了（end_turn），活还在跑，跑完会叫醒会话接着做
      my $old = $now - $PENDING_MAX_SEC;
      for my $bk (keys %{ $st->{bg} }) { delete $st->{bg}{$bk} if $st->{bg}{$bk} < $old }
      $status = 'running' if ($status eq 'done' || $status eq 'idle') && %{ $st->{bg} };
      # 在等我：弹出来要我点的提问 / 计划审批 / 开新会话卡片还没答（这一轮结尾“下一步”框里的问题不算：那一轮已经做完了）
      $st->{waitId} = '' if $st->{waitId} ne '' && defined $st->{waitAt} && $st->{waitAt} < $old;
      my $asking = ($st->{waitId} ne '');
      $status = 'input' if $asking;
      # 会话自己报的“在等我决定”（授权框、提问、MCP 表单）比上面的猜测准：标记之后 transcript 没有新内容就算数
      # （答完会写工具结果，transcript 就比标记新了；会话没来得及清掉标记也不会一直挂着）
      my $flag = "$inputDir/$id";
      if (-f $flag) {
        my $ms = slurp($flag) // '';
        $ms =~ s/^\s+|\s+$//g;
        if ($ms =~ /^\d+$/) {
          my $flagAt = $ms / 1000;
          $status = 'input' if $flagAt >= $mtime - 2;
        }
      }

      my ($done, $total, $current) = (0, 0, '');
      # 步骤明细：标题、状态、耗时（秒；完成 = 结束 - 开始，进行中 = 现在 - 开始，未开始 = -1）
      my @steps; my $first; my $lastEnd; my $open = 0;
      my $stepOf = sub {
        my ($title, $s, $t) = @_;
        my $sec = -1;
        if ($t && defined $t->{a}) {
          $sec = ($s eq 'completed' && defined $t->{e}) ? int($t->{e} - $t->{a}) : ($s eq 'in_progress') ? int($now - $t->{a}) : -1;
        }
        $sec = -1 if $sec < -1;
        return { t => $title, s => $s, sec => $sec };
      };
      my @timed;
      if (@{ $st->{taskOrder} }) {
        for my $k (@{ $st->{taskOrder} }) {
          my $t = $st->{tasks}{$k} or next;
          $total++;
          if ($t->{s} eq 'completed') { $done++ } elsif ($t->{s} eq 'in_progress' && $current eq '') { $current = $t->{t} }
          push @steps, $stepOf->($t->{t}, $t->{s}, $t); push @timed, [$t, $t->{s}];
        }
      } elsif ($st->{todos}) {
        for my $t (@{ $st->{todos} }) {
          next unless ref $t eq 'HASH';
          my $s = str($t->{status});
          $total++;
          if ($s eq 'completed') { $done++ } elsif ($s eq 'in_progress' && $current eq '') { $current = str($t->{activeForm}) }
          my $tt = $st->{todoT}{ str($t->{content}) };
          push @steps, $stepOf->(str($t->{content}), $s, $tt); push @timed, [$tt, $s];
        }
      }
      # 总耗时：第一个步骤建立起；还有没做完的算到现在，全做完算到最后一步完成
      for my $p (@timed) {
        my $t = $p->[0] or next;
        $first = $t->{c} if defined $t->{c} && (!defined $first || $t->{c} < $first);
        if ($p->[1] ne 'completed') { $open = 1 }
        elsif (defined $t->{e} && (!defined $lastEnd || $t->{e} > $lastEnd)) { $lastEnd = $t->{e} }
      }
      # 清单全部做完、而且是在这一轮提问之前做完的：它属于上一件事，这一轮当作没有清单（不显示 100%）
      if ($total > 0 && !$open && defined $lastEnd && defined $st->{turnAt} && $lastEnd < $st->{turnAt}) {
        @steps = (); $done = 0; $total = 0; $current = ''; $first = undef;
      }
      my $planSec = -1;
      if (defined $first) { $planSec = int((($open || !defined $lastEnd) ? $now : $lastEnd) - $first) }
      my $turnSec = defined $st->{turnAt} ? int($now - $st->{turnAt}) : -1;
      splice(@steps, 40) if @steps > 40;
      # 每个子代理是哪一步派出去的：它开始时正在进行的那一步（同时有几步在进行就取最晚开始的）；
      # step = 在 steps 里的序号，-1 = 不在任何一步里（没有清单，或者在两步之间）
      for my $r (@subRows) {
        my $best = -1; my $bestA = -1;
        if (@steps && $r->{at} > 0) {
          my $n = @timed < @steps ? @timed : @steps;
          for (my $k = 0; $k < $n; $k++) {
            my $t = $timed[$k][0];
            next unless $t && defined $t->{a};
            my $a = $t->{a}; my $e = defined $t->{e} ? $t->{e} : 1e18;
            if ($a <= $r->{at} && $r->{at} <= $e && $a >= $bestA) { $best = $k; $bestA = $a }
          }
        }
        $r->{step} = $best;
        delete $r->{at};
      }

      my $d = $desk->{$id};
      my $title = ($d && $d->{title} ne '') ? $d->{title} : $st->{title} ne '' ? $st->{title} : $st->{prompt} ne '' ? $st->{prompt} : substr($id, 0, 8);
      my $link = ($d && $d->{local} ne '') ? "claude://claude.ai/epitaxy/$d->{local}" : '';
      my $bridge = $d ? $d->{bridge} : '';
      my $project = $st->{cwd} ne '' ? basename($st->{cwd}) : '';
      return {
        id => $id, title => $title, link => $link, bridge => $bridge, project => $project, status => $status,
        ageSec => int($age), msgAgeSec => int($msgAge), cacheAgeSec => $cacheAge, done => $done, total => $total, current => $current,
        input => $st->{tin} + $sub{tin}, cacheWrite => $st->{tcw} + $sub{tcw}, cacheRead => $st->{tcr} + $sub{tcr}, output => $st->{tout} + $sub{tout},
        subagents => $sub{n}, subActive => $sub{active},
        model => $st->{model}, effort => $st->{effort},
        steps => [ map { { t => $_->{t}, s => $_->{s}, sec => $_->{sec} } } @steps ], planSec => $planSec, turnSec => $turnSec,
        subs => [ map { { %$_, active => ($_->{active} ? JSON::PP::true : JSON::PP::false) } } @subRows ],
      };
    };
    push @out, $row if $row;
  }
  my $nextSteps = JSON::PP::true;
  my %hidden;
  my $liveActivity = JSON::PP::true;
  if (-f $prefsPath) {
    my $p = eval { $jsonIn->decode(slurp($prefsPath) // '') };
    if ($p && ref $p eq 'HASH') {
      $nextSteps = JSON::PP::false if defined $p->{nextSteps} && !$p->{nextSteps};
      # 本机的 iPhone Live 开关：关了推送器就不往手机推（手机上自己的开关也要开着才推）
      $liveActivity = JSON::PP::false if defined $p->{liveActivity} && !$p->{liveActivity};
      # 任务板上手动隐藏的已完成会话：会话 id -> 隐藏时它最后一次请求的时间（毫秒）
      if (ref $p->{hidden} eq 'HASH') { $hidden{$_} = 0 + $p->{hidden}{$_} for keys %{ $p->{hidden} } }
    }
  }
  my $usageText = '';
  if (-f $usagePath) { my $t = slurp($usagePath); $usageText = defined $t ? decode('UTF-8', $t) : '' }
  my $nowMs = int($now * 1000);
  my $sharedWarn = $shared ne '' ? upload_check($now) : '';
  my $line = $json->encode({
    at => $nowMs, device => $device, os => $os, sessions => \@out,
    prefs => { nextSteps => $nextSteps, hidden => \%hidden, liveActivity => $liveActivity }, prefsPath => $prefsPath,
    usagePath => $usagePath, usageText => $usageText, inputDir => $inputDir,
    (-f $livePath ? (livePusher => JSON::PP::true) : ()),
    ($sharedWarn ne '' ? (sharedWarn => $sharedWarn) : ()),
  });
  my $writeSnap = $now - $lastSnap >= 10;
  # 跨设备共享：本机快照（不含 remote，不然两边会互相套进去越滚越大）写到共享目录；再读其他电脑的快照
  if ($shared ne '') {
    write_in_place($line, "$shared/$device.json") if $writeSnap;
    my @remote;
    if (opendir(my $dh, $shared)) {
      for my $name (sort readdir($dh)) {
        # 同步盘给本机文件生成的冲突副本（Mac 2.json、Mac(1).json）和残留的临时文件：是本机自己的东西，删掉。
        # 但 iCloud 有时把刚原地写好的 Mac.json 直接改名成冲突名：那份就是最新的快照，马上删的话别的电脑上这台的会话时有时无。
        # 所以只删 30 秒没更新的；读的一方按 device 留最新的
        if ($name =~ /^\Q$device\E( \d+|\(\d+\))\.json$/ || $name =~ /^\Q$device\E\.json\..*\.tmp$/) {
          my @st = stat("$shared/$name");
          unlink "$shared/$name" if @st && $now - $st[9] >= 30;
          next;
        }
        next unless $name =~ /\.json$/ && $name ne "$device.json";
        # iCloud 还没下载下来的文件（有大小、没占磁盘块）：读它会一直等下载，整个扫描卡住（2026-10-13 卡过一个多小时）。
        # 先跳过，叫 iCloud 去下载（它自己不会下：别的电脑新生成的冲突名文件一直停在没下载的状态），下载好了下一轮再读；
        # 万一读起来还是卡，2 秒后放弃这一份
        my @st = stat("$shared/$name");
        next unless @st;
        if ($st[7] > 0 && $st[12] == 0) {
          request_download("$shared/$name");
          next;
        }
        # 菜单栏起的扫描自带一个每 5 秒查父进程的闹钟（menubar.js 的 GUARD）：借用完把它的剩余时间还回去
        my $guardLeft = alarm 0;
        my $text = eval {
          local $SIG{ALRM} = sub { die "timeout\n" };
          alarm 2;
          my $t = slurp("$shared/$name");
          alarm 0;
          $t;
        };
        alarm 0;
        alarm($guardLeft > 0 ? $guardLeft : 1) if ref $SIG{ALRM} eq 'CODE';
        next unless defined $text;
        $text =~ s/^\s+|\s+$//g;
        next unless $text =~ /^\{.*\}$/s;
        my $head = eval { $jsonIn->decode($text) } or next;
        # 要有本机名和时间；本机名和自己一样的（同步盘的冲突副本）不要；太久没更新的 = 离线，跳过
        next unless ref $head eq 'HASH' && defined $head->{device} && !ref $head->{device} && $head->{device} ne '' && $head->{device} ne $device;
        my $at = $head->{at};
        next unless defined $at && !ref $at && $at =~ /^\d+$/ && $nowMs - $at <= $SHARED_MAX_MS;
        # 原样附上（共享目录里的快照本来就不含 remote）；不是纯 ASCII 的（别的工具写的）重新编码一遍，输出保持纯 ASCII
        $text = $json->encode($head) if $text =~ /[^\x00-\x7F]/;
        push @remote, $text;
      }
      closedir $dh;
    }
    $line = substr($line, 0, -1) . ',"remote":[' . join(',', @remote) . ']}' if @remote;
  }
  print STDOUT "$line\n";
  STDOUT->flush();
  swap_in($line, $latest) if $latest ne '';
  swap_in($line, $leadPath) unless $once;
  # 本机的共用快照最多 10 秒写一次（带 remote：新会话一启动就能看到别的电脑）
  if ($writeSnap) {
    $lastSnap = $now;
    swap_in($line, $snapPath);
  }
}

# iCloud 上传卡住的检查（见开头 $BRCTL 那段）。返回提示文字，'' = 没卡（或还没到检查时间、或共享目录不在 iCloud 里）
sub upload_check {
  my ($now) = @_;
  return '' unless $ENV{TASK_BOARD_BRCTL} || $shared =~ m{/Mobile Documents/com~apple~CloudDocs/};
  my $probe = "$shared/$device-upload-check.txt";
  if (!$uploadProbeAt) {
    return upload_warn($now) if $now - $uploadLastCheck < ($uploadStuckSince ? 60 : 300);
    write_in_place("$now\n", $probe);
    $uploadProbeAt = $now;
  }
  return upload_warn($now) if $now - $uploadProbeAt < $UPLOAD_WAIT_SEC;
  # brctl status 平时不到 1 秒，队列堆了几千条时要几秒：最多等 8 秒（闹钟借用的套路同读远端快照）
  my $guardLeft = alarm 0;
  my $text = eval {
    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm 8;
    my $t = `"$BRCTL" status com.apple.CloudDocs 2>/dev/null`;
    alarm 0;
    $t;
  };
  alarm 0;
  alarm($guardLeft > 0 ? $guardLeft : 1) if ref $SIG{ALRM} eq 'CODE';
  my $wrote = $uploadProbeAt;
  ($uploadProbeAt, $uploadLastCheck) = (0, $now);
  return upload_warn($now) unless defined $text;   # brctl 没跑成：这次不下结论
  # brctl 把文件名缩写成 首字{中间几个}尾字.扩展名（Mac.json → M{1}c.json）
  my $name = "$device-upload-check";
  my $abbr = length($name) > 2 ? substr($name, 0, 1) . '{' . (length($name) - 2) . '}' . substr($name, -1) : $name;
  my @pending = grep { /up:needs-sync-up/ } split /\n/, $text;
  if (grep { index($_, "n:\"$abbr.txt\"") >= 0 } @pending) {
    $uploadStuckSince ||= $wrote;
    $uploadPending = scalar @pending;
  } else {
    ($uploadStuckSince, $uploadPending) = (0, 0);
    unlink $probe;
  }
  return upload_warn($now);
}

sub upload_warn {
  my ($now) = @_;
  return '' unless $uploadStuckSince;
  my $min = int(($now - $uploadStuckSince) / 60);
  return "iCloud has not uploaded this computer's snapshot for $min min ($uploadPending files waiting): other computers and the phone can't see its sessions";
}

# 叫 iCloud 下载共享目录里还没下载的文件：后台跑 brctl，不等它；同一个文件 10 秒内只叫一次
my %downloadAsked;
sub request_download {
  my ($path) = @_;
  1 while waitpid(-1, POSIX::WNOHANG()) > 0;   # 收掉上次的 brctl
  return if time() - ($downloadAsked{$path} // 0) < 10;
  $downloadAsked{$path} = time();
  return unless -x '/usr/bin/brctl';
  my $pid = fork() // return;
  return if $pid;
  open(STDIN, '<', '/dev/null');
  open(STDOUT, '>', '/dev/null');
  open(STDERR, '>', '/dev/null');
  exec('/usr/bin/brctl', 'download', $path) or POSIX::_exit(0);
}

# 还没拿到锁就试一次（不等）：拿到了从此就是主扫描，锁跟着进程，进程退出系统自动放锁
sub try_lead {
  return 1 if $isLead;
  open($lockFh, '>>', $lockPath) or return 0;
  if (flock($lockFh, LOCK_EX | LOCK_NB)) { $isLead = 1; return 1 }
  close $lockFh;
  $lockFh = undef;
  return 0;
}

# 跟随的一轮：原样转发主扫描最近的一行（太旧就这轮不出，等下一轮或自己接手）
sub follow_round {
  my @s = stat($leadPath);
  return unless @s && time() - $s[9] < $LEAD_MAX_SEC;
  my $line = slurp($leadPath) // return;
  $line =~ s/\s+$//;
  return unless $line =~ /^\{.*\}$/s;
  print STDOUT "$line\n";
  STDOUT->flush();
  swap_in($line, $latest) if $latest ne '';
}

do {
  # --lead-only 拿不到锁：告诉调用方去读主扫描的输出文件，自己退出（--once 不排队，到不了这里）
  if ($leadOnly && !try_lead()) {
    my $line = $json->encode({ follow => $leadPath });
    print STDOUT "$line\n";
    STDOUT->flush();
    swap_in($line, $latest) if $latest ne '';
    exit 0;
  }
  if (try_lead()) { scan_round() } else { follow_round() }
  sleep($intervalMs / 1000) unless $once;
} while (!$once);
