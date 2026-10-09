#!/usr/bin/perl
# scan.pl 的测试：在临时目录里造几份 transcript 和桌面应用的会话元数据，跑一次 --once，核对输出。
#   perl task-board/tests/scan.t
use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use JSON::PP;
use Encode ();
use POSIX qw(strftime);

my $here = dirname(__FILE__);
my $scan = "$here/../scan.pl";
my $home = tempdir(CLEANUP => 1);
my $app = "$home/app-sessions";
my $proj = "$home/.claude/projects/-Users-u-work";
make_path($proj, $app, "$home/.claude");

sub iso { my ($t) = @_; return strftime('%Y-%m-%dT%H:%M:%S', gmtime($t)) . '.000Z' }
sub put { my ($p, $t) = @_; make_path(dirname($p)); open(my $fh, '>:raw', $p) or die; print $fh $t; close $fh }
sub touch { my ($p, $t) = @_; utime($t, $t, $p) }
my $J = JSON::PP->new->utf8->canonical;

# transcript 的键顺序和真的一样（扫描脚本的正则按真实顺序写）：obj(k => v, ...) 按给的顺序输出，
# 值可以是 obj()、数组、字符串、数字、JSON::PP::true/false
package Raw { sub new { my ($c, $s) = @_; return bless \$s, $c } }
sub val {
  my ($v) = @_;
  return $$v if ref $v eq 'Raw';
  return '[' . join(',', map { val($_) } @$v) . ']' if ref $v eq 'ARRAY';
  return $J->encode([$v]) =~ s/^\[|\]$//gr;
}
sub obj {
  my @p = @_;
  return Raw->new('{}') if !@p;
  return Raw->new('{' . join(',', map { val('' . $p[$_ * 2]) . ':' . val($p[$_ * 2 + 1]) } 0 .. $#p / 2) . '}');
}
sub line { return ${ obj(@_) } }
# 一条回答：message 在前（model, id, type, role, content, stop_reason, usage），type / uuid / timestamp 在后，和真的一样
sub assistant {
  my (%o) = @_;
  return line(parentUuid => 'p', isSidechain => JSON::PP::false,
    message => obj(model => $o{model}, id => $o{id}, type => 'message', role => 'assistant', content => $o{content},
      ($o{stop} ? (stop_reason => $o{stop}) : ()),
      usage => obj(input_tokens => $o{in}, cache_creation_input_tokens => $o{cw}, cache_read_input_tokens => $o{cr}, output_tokens => $o{out})),
    ($o{effort} ? (effort => $o{effort}) : ()),
    type => 'assistant', uuid => $o{uuid}, timestamp => $o{ts}, cwd => $o{cwd} // '/Users/u/work');
}
sub tool { my ($id, $name, $input) = @_; return obj(type => 'tool_use', id => $id, name => $name, input => $input) }
sub human {
  my ($uuid, $ts, $text, $cwd) = @_;
  return line(parentUuid => undef, isSidechain => JSON::PP::false, type => 'user',
    message => obj(role => 'user', content => $text), uuid => $uuid, timestamp => $ts, ($cwd ? (cwd => $cwd) : ()), origin => obj(kind => 'human'));
}

my $now = time();
my $t0 = $now - 600;   # 这一轮 10 分钟前开始

# ── 会话 a：有任务清单（TaskCreate / TaskUpdate）、一个在跑的子代理、停在工具调用上 ──
my @a;
push @a, line(type => 'custom-title', customTitle => "发布 \"说明\"", sessionId => 'aaaa');
push @a, human('u1', iso($t0), '开始', '/Users/u/work');
# 第一次回答：建两个任务
push @a, assistant(id => 'msg_1', model => 'claude-opus-5-5', uuid => 'a1', ts => iso($t0 + 5), stop => 'tool_use', effort => 'high',
  content => [ tool('tu1', 'TaskCreate', obj(subject => 'Survey: Read notes')), tool('tu2', 'TaskCreate', obj(subject => 'Renumber: Set prefix')) ],
  in => 100, cw => 200, cr => 300, out => 40);
# 第一步开始、完成；第二步开始
push @a, assistant(id => 'msg_2', model => 'claude-opus-5-5', uuid => 'a2', ts => iso($t0 + 10), stop => 'tool_use',
  content => [ tool('tu3', 'TaskUpdate', obj(taskId => '1', status => 'in_progress')) ], in => 10, cw => 0, cr => 600, out => 20);
push @a, assistant(id => 'msg_3', model => 'claude-opus-5-5', uuid => 'a3', ts => iso($t0 + 130), stop => 'tool_use',
  content => [ tool('tu4', 'TaskUpdate', obj(taskId => '1', status => 'completed')), tool('tu5', 'TaskUpdate', obj(taskId => '2', status => 'in_progress')) ],
  in => 10, cw => 0, cr => 600, out => 20);
# 同一条消息的流式更新：usage 以最后一次为准（不重复计）
push @a, assistant(id => 'msg_3', model => 'claude-opus-5-5', uuid => 'a4', ts => iso($t0 + 131), stop => 'tool_use',
  content => [ tool('tu6', 'Bash', obj(command => 'ls')) ], in => 10, cw => 0, cr => 600, out => 60);
put("$proj/aaaa.jsonl", join("\n", @a) . "\n");
touch("$proj/aaaa.jsonl", $now - 200);   # 200 秒没动：不算 running，停在 tool_use 上 = waiting
# 子代理：第二步进行中派出的，还在跑
my @s;
push @s, line(type => 'user', message => obj(role => 'user', content => 'go'), uuid => 's0', timestamp => iso($t0 + 140));
push @s, assistant(id => 'msg_s1', model => 'claude-haiku-4-5-20251001', uuid => 's1', ts => iso($t0 + 150), stop => 'tool_use',
  content => [ tool('x1', 'Grep', obj()), tool('x2', 'Read', obj()) ], in => 5, cw => 0, cr => 0, out => 7);
put("$proj/aaaa/subagents/agent-1.jsonl", join("\n", @s) . "\n");
touch("$proj/aaaa/subagents/agent-1.jsonl", $now - 10);
put("$proj/aaaa/subagents/agent-1.meta.json", $J->encode({ agentType => 'Explore', description => 'old notes' }));

# ── 会话 b：回答完了（end_turn），桌面应用里有标题和链接；用 TodoWrite 的清单 ──
my @b;
push @b, human('u1', iso($t0), 'x', '/Users/u/other');
push @b, assistant(id => 'msg_b1', model => 'claude-sonnet-5-5', cwd => '/Users/u/other', uuid => 'b1', ts => iso($t0 + 5), stop => 'tool_use',
  content => [ tool('tb1', 'TodoWrite', obj(todos => [
    obj(content => '写文档', status => 'in_progress', activeForm => '写文档中'), obj(content => '提交', status => 'pending', activeForm => '提交中') ])) ],
  in => 1, cw => 2, cr => 3, out => 4);
push @b, assistant(id => 'msg_b2', model => 'claude-sonnet-5-5', cwd => '/Users/u/other', uuid => 'b2', ts => iso($t0 + 65), stop => 'end_turn',
  content => [ obj(type => 'text', text => '好了') ], in => 1, cw => 2, cr => 3, out => 4);
put("$proj/bbbb.jsonl", join("\n", @b) . "\n");
touch("$proj/bbbb.jsonl", $now - 300);
put("$app/x/y/local_b.json", $J->encode({ sessionId => 'local_bbbb-1', cliSessionId => 'bbbb', isArchived => JSON::PP::false,
  title => "别的会话 \\ 标题", priorCliSessionIds => ['bbbb-old'] }));
# 被 b 接替的旧 transcript：不显示
put("$proj/bbbb-old.jsonl", $b[0] . "\n");
touch("$proj/bbbb-old.jsonl", $now - 100);

# ── 会话 c：已归档，不显示 ──
put("$proj/cccc.jsonl", $b[0] . "\n");
touch("$proj/cccc.jsonl", $now - 100);
put("$app/local_c.json", $J->encode({ sessionId => 'local_cccc', cliSessionId => 'cccc', isArchived => JSON::PP::true, title => 'c' }));

# ── 会话 d：在等我决定（标记文件比 transcript 新）；刚才还在跑 ──
put("$proj/dddd.jsonl", line(type => 'last-prompt', lastPrompt => '帮我看看', sessionId => 'dddd') . "\n" . $b[0] . "\n");
touch("$proj/dddd.jsonl", $now - 30);
make_path("$home/.claude/task-board-input");
put("$home/.claude/task-board-input/dddd", '' . (int($now) * 1000));

# ── 会话 e：太久没动（超过 --hours），不显示 ──
put("$proj/eeee.jsonl", $b[0] . "\n");
touch("$proj/eeee.jsonl", $now - 30 * 3600);

# 开关文件、用量文件
put("$home/.claude/task-board-prefs.json", $J->encode({ nextSteps => JSON::PP::false, hidden => { zzzz => 1790000000000 } }));
put("$home/.claude/task-board-usage.json", "{\"at\":1,\"limits\":[]}\n");

my $out = `/usr/bin/perl "$scan" --once --home "$home" --app "$app" --hours 24 --max 12`;
is($?, 0, 'scan.pl exits 0');
like($out, qr/^[\x00-\x7F]*$/, 'output is pure ASCII (non-ASCII escaped)');
my $got = JSON::PP->new->utf8->decode($out);
ok(abs($got->{at} / 1000 - $now) < 5, 'at = now (ms)');
is($got->{prefsPath}, "$home/.claude/task-board-prefs.json", 'prefsPath');
is($got->{inputDir}, "$home/.claude/task-board-input", 'inputDir');
ok(!$got->{prefs}{nextSteps}, 'prefs.nextSteps read from file');
is($got->{prefs}{hidden}{zzzz}, 1790000000000, 'prefs.hidden read from file');
is($got->{usageText}, "{\"at\":1,\"limits\":[]}\n", 'usageText passed through');
ok(-f "$home/.claude/task-board-snapshot.json", 'snapshot written');
is($got->{os}, 'mac', 'os = mac');
ok(defined $got->{device} && $got->{device} ne '', 'device defaults to the host name');
ok(!exists $got->{remote}, 'no --shared: no remote');

my %s = map { $_->{id} => $_ } @{ $got->{sessions} };
is_deeply([sort keys %s], ['aaaa', 'bbbb', 'dddd'], 'archived, superseded and old sessions are left out');

my $a = $s{aaaa};
is($a->{title}, '发布 "说明"', 'title from custom-title, unescaped');
is($a->{project}, 'work', 'project = last path component of cwd');
is($a->{status}, 'running', 'a is running (a subagent is active)');
is($a->{link}, '', 'no desktop metadata = no link');
is_deeply([ map { [$_->{t}, $_->{s}] } @{ $a->{steps} } ], [['Survey: Read notes', 'completed'], ['Renumber: Set prefix', 'in_progress']], 'steps');
is($a->{steps}[0]{sec}, 120, 'completed step: end - start');
ok($a->{steps}[1]{sec} >= 469 && $a->{steps}[1]{sec} <= 472, 'running step: now - start');
is("$a->{done}/$a->{total}", '1/2', 'done/total');
is($a->{current}, 'Renumber: Set prefix', 'current step');
is($a->{model}, 'claude-opus-5-5', 'model');
is($a->{effort}, 'high', 'effort');
is($a->{input}, 100 + 10 + 10 + 5, 'input tokens: streamed update of msg_3 counted once, subagent added');
is($a->{output}, 40 + 20 + 60 + 7, 'output tokens');
is($a->{cacheRead}, 300 + 600 + 600, 'cache read');
ok($a->{cacheAgeSec} >= 468 && $a->{cacheAgeSec} <= 471, 'cacheAgeSec from the last main-transcript request');
ok($a->{planSec} >= 594 && $a->{planSec} <= 597, 'planSec from the first task created');
ok($a->{turnSec} >= 599 && $a->{turnSec} <= 602, 'turnSec from the human prompt');
is($a->{subagents}, 1, 'one subagent');
is($a->{subActive}, 1, 'it is active');
my $sub = $a->{subs}[0];
is($sub->{name}, 'Explore', 'subagent type from .meta.json');
is($sub->{desc}, 'old notes', 'subagent description');
is($sub->{model}, 'claude-haiku-4-5-20251001', 'subagent model');
is($sub->{tool}, 'Read', 'last tool of an active subagent');
is($sub->{calls}, 2, 'tool calls');
ok($sub->{active}, 'active');
is($sub->{step}, 1, 'started while step 2 was in progress');
ok(!exists $sub->{at}, 'at removed from the output');

my $b = $s{bbbb};
is($b->{title}, '别的会话 \\ 标题', 'title from the desktop app wins');
is($b->{link}, 'claude://claude.ai/epitaxy/local_bbbb-1', 'link from the desktop app');
is($b->{status}, 'done', 'end_turn = done');
is($b->{project}, 'other', 'project');
is_deeply([ map { [$_->{t}, $_->{s}] } @{ $b->{steps} } ], [['写文档', 'in_progress'], ['提交', 'pending']], 'TodoWrite steps');
is($b->{current}, '写文档中', 'current = activeForm');
is($b->{steps}[1]{sec}, -1, 'pending step has no time');

my $d = $s{dddd};
is($d->{title}, '帮我看看', 'title falls back to last-prompt');
is($d->{status}, 'input', 'needs-input flag newer than the transcript = input');

# 第二轮：清单做完了，然后来了新一轮提问
push @b, assistant(id => 'msg_b3', model => 'claude-sonnet-5-5', uuid => 'b3', ts => iso($t0 + 70), stop => 'end_turn',
  content => [ tool('tb2', 'TodoWrite', obj(todos => [
    obj(content => '写文档', status => 'completed', activeForm => '写文档中'), obj(content => '提交', status => 'completed', activeForm => '提交中') ])) ],
  in => 1, cw => 2, cr => 3, out => 4);
push @b, human('u2', iso($now - 5), '再来');
put("$proj/bbbb.jsonl", join("\n", @b) . "\n");
touch("$proj/bbbb.jsonl", $now - 5);
$out = `/usr/bin/perl "$scan" --once --home "$home" --app "$app"`;
$got = JSON::PP->new->utf8->decode($out);
%s = map { $_->{id} => $_ } @{ $got->{sessions} };
is($s{bbbb}{status}, 'running', 'a new human prompt makes the session running again');
is($s{bbbb}{total}, 0, 'a list finished before this turn is not shown');

# ── 跨设备共享：共享目录里一份别的电脑的、一份过期的、一份本机名的冲突副本、一份坏的、一份临时文件 ──
my $sh = "$home/shared";
my $nowMs = int($now * 1000);
# 标题故意用没转义的 UTF-8（别的工具写的快照可能这样），输出仍要是纯 ASCII
my $row = '{"id":"win-1111","title":"Win 上的会话","link":"claude://claude.ai/epitaxy/local_x","project":"p","status":"running","ageSec":5,"cacheAgeSec":5,"done":1,"total":3,"current":"x","input":1,"cacheWrite":2,"cacheRead":3,"output":4,"subagents":0,"subActive":0,"steps":[],"planSec":10,"turnSec":12,"subs":[]}';
put("$sh/WinPC.json", Encode::encode('UTF-8', "{\"at\":$nowMs,\"device\":\"WinPC\",\"os\":\"win\",\"sessions\":[$row],\"prefs\":{\"nextSteps\":true,\"hidden\":{}}}\n"));
put("$sh/Old.json", '{"at":' . ($nowMs - 11 * 60 * 1000) . ',"device":"Old","os":"win","sessions":[]}');
put("$sh/Mini 2.json", "{\"at\":$nowMs,\"device\":\"Mini\",\"os\":\"mac\",\"sessions\":[]}");
put("$sh/Junk.json", 'not json');
put("$sh/WinPC.json.999.tmp", '{"at":1,"device":"Tmp","sessions":[]}');
$out = `/usr/bin/perl "$scan" --once --home "$home" --app "$app" --shared "$sh" --device Mini`;
is($?, 0, 'scan.pl --shared exits 0');
like($out, qr/^[\x00-\x7F]*$/, 'output with remote is still pure ASCII');
$got = JSON::PP->new->utf8->decode($out);
is($got->{device}, 'Mini', 'device from --device');
is(scalar @{ $got->{remote} }, 1, 'one other computer: stale, own-name copy, junk and tmp files skipped');
is($got->{remote}[0]{device}, 'WinPC', 'remote device');
is($got->{remote}[0]{os}, 'win', 'remote os');
is($got->{remote}[0]{sessions}[0]{title}, 'Win 上的会话', 'remote session passed through unchanged');
ok(!exists $got->{remote}[0]{remote}, 'remote snapshot carries no remote of its own');
my $mine = JSON::PP->new->utf8->decode(slurp_t("$sh/Mini.json"));
is($mine->{device}, 'Mini', 'own snapshot written to the shared folder');
ok(!exists $mine->{remote}, 'the shared copy has no remote (no nesting)');
is(scalar @{ $mine->{sessions} }, 3, 'the shared copy has the sessions');
my $snap = JSON::PP->new->utf8->decode(slurp_t("$home/.claude/task-board-snapshot.json"));
is(scalar @{ $snap->{remote} }, 1, 'the local snapshot includes remote');
# ~ 展开成 --home；设备名默认主机名
$out = `/usr/bin/perl "$scan" --once --home "$home" --app "$app" --shared "~/tilde/shared"`;
$got = JSON::PP->new->utf8->decode($out);
ok(-f "$home/tilde/shared/$got->{device}.json", '~ in --shared = home; file named after the host');

sub slurp_t { my ($p) = @_; open(my $fh, '<:raw', $p) or return ''; local $/; my $t = <$fh>; close $fh; return $t }

done_testing();
