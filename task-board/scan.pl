#!/usr/bin/perl
# 增量扫描 ~/.claude/projects 下各会话的 transcript，每轮输出一行 JSON。
# macOS 版：每台 Mac 自带 /usr/bin/perl（5.34，含 JSON::PP），不用另装任何东西。
# 和 Windows 版 scan.ps1 逐段对应，输出格式完全一样。
#
#   perl scan.pl [--once] [--hours 24] [--max 12] [--interval-ms 3000] [--shared DIR] [--device NAME] [--home DIR] [--app DIR]
#   --shared DIR  跨设备共享目录（同步盘里）：每 10 秒把本机快照写成 DIR/<device>.json，每轮读目录里其他电脑的快照附在 remote 里
#   --device NAME 本机标签（卡片上的灰色小标签，也是共享目录里的文件名；空 = Mac）
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

my ($once, $hours, $max, $intervalMs) = (0, 24, 12, 3000);
my $home = $ENV{HOME} // (getpwuid($<))[7];
my $appRoot;
my ($shared, $device) = ('', '');
while (@ARGV) {
  my $a = shift @ARGV;
  if ($a eq '--once') { $once = 1 }
  elsif ($a eq '--hours') { $hours = 0 + shift @ARGV }
  elsif ($a eq '--max') { $max = 0 + shift @ARGV }
  elsif ($a eq '--interval-ms') { $intervalMs = 0 + shift @ARGV }
  elsif ($a eq '--home') { $home = shift @ARGV }
  elsif ($a eq '--app') { $appRoot = shift @ARGV }
  elsif ($a eq '--shared') { $shared = shift @ARGV // '' }
  elsif ($a eq '--device') { $device = shift @ARGV // '' }
}
my $root = "$home/.claude/projects";
# 全局开关（所有会话共用）：任务板上按一下就改这个文件，各会话的扫描进程每轮都重读
my $prefsPath = "$home/.claude/task-board-prefs.json";
# 账号用量（5 小时 / 每周额度）：哪个会话拿到新读数就写这里，扫描进程原样转给所有会话
my $usagePath = "$home/.claude/task-board-usage.json";
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
    }
    if ($line =~ $rxKind) {
      $st->{kind} = $1;
      if ($st->{kind} eq 'assistant') {
        if ($line =~ $rxModel) { $st->{model} = $1 }
        my @tools = ($line =~ /$rxTool/g);
        if (@tools) { $st->{tool} = $tools[-1]; $st->{calls} += scalar @tools }
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
      $c = {
        mtime => $mtime,
        local => $local // '',
        cli => $cli // '',
        archived => (defined $arch && $arch eq 'true') ? 1 : 0,
        title => defined $title ? unesc($title) : '',
        prior => defined $priorList ? [ $priorList =~ /"([^"]+)"/g ] : [],
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

# 先写临时文件再整个换上（rename 是原子的），读的一方不会读到半个文件；几个会话同时写，谁后换上算谁的
sub swap_in {
  my ($text, $dest) = @_;
  my $tmp = "$dest.$$.tmp";
  open(my $fh, '>:raw', $tmp) or return;
  print $fh $text;
  close $fh;
  rename($tmp, $dest) or unlink $tmp;
}

do {
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
      # 主会话的缓存只被主 transcript 里的请求续期（子代理用自己的缓存前缀）
      my $cacheAge = defined $st->{lastReq} ? int($now - $st->{lastReq}) : -1;

      # 状态：根据最后一条消息和文件多久没动
      my $status;
      if ($sub{active} > 0) { $status = 'running' }
      elsif ($st->{kind} eq 'assistant' && $st->{stop} eq 'end_turn') { $status = 'done' }
      elsif ($age < 90) { $status = 'running' }
      elsif ($st->{kind} eq 'assistant' && $st->{stop} eq 'tool_use') { $status = 'waiting' }
      else { $status = 'idle' }
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
      my $project = $st->{cwd} ne '' ? basename($st->{cwd}) : '';
      return {
        id => $id, title => $title, link => $link, project => $project, status => $status,
        ageSec => int($age), cacheAgeSec => $cacheAge, done => $done, total => $total, current => $current,
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
  if (-f $prefsPath) {
    my $p = eval { $jsonIn->decode(slurp($prefsPath) // '') };
    if ($p && ref $p eq 'HASH') {
      $nextSteps = JSON::PP::false if defined $p->{nextSteps} && !$p->{nextSteps};
      # 任务板上手动隐藏的已完成会话：会话 id -> 隐藏时它最后一次请求的时间（毫秒）
      if (ref $p->{hidden} eq 'HASH') { $hidden{$_} = 0 + $p->{hidden}{$_} for keys %{ $p->{hidden} } }
    }
  }
  my $usageText = '';
  if (-f $usagePath) { my $t = slurp($usagePath); $usageText = defined $t ? decode('UTF-8', $t) : '' }
  my $nowMs = int($now * 1000);
  my $line = $json->encode({
    at => $nowMs, device => $device, os => $os, sessions => \@out,
    prefs => { nextSteps => $nextSteps, hidden => \%hidden }, prefsPath => $prefsPath,
    usagePath => $usagePath, usageText => $usageText, inputDir => $inputDir,
  });
  my $writeSnap = $now - $lastSnap >= 10;
  # 跨设备共享：本机快照（不含 remote，不然两边会互相套进去越滚越大）写到共享目录；再读其他电脑的快照
  if ($shared ne '') {
    swap_in($line, "$shared/$device.json") if $writeSnap;
    my @remote;
    if (opendir(my $dh, $shared)) {
      for my $name (sort readdir($dh)) {
        next unless $name =~ /\.json$/ && $name ne "$device.json";
        my $text = slurp("$shared/$name") // next;
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
  # 本机的共用快照最多 10 秒写一次（带 remote：新会话一启动就能看到别的电脑）
  if ($writeSnap) {
    $lastSnap = $now;
    swap_in($line, $snapPath);
  }
  sleep($intervalMs / 1000) unless $once;
} while (!$once);
