#!/usr/bin/perl
# 演示用：在 ~/.claude/projects 里造一个“正在跑”的会话，分阶段的任务清单一步步推进，
# 每一步派出 1–2 个子代理，让任务板的明细面板有东西可看。约 3 分钟跑完，然后把文件删掉。
#   perl task-board/tests/demo-session.pl [--keep]
use strict;
use warnings;
use utf8;
use JSON::PP;
use File::Path qw(make_path remove_tree);
use POSIX qw(strftime);

my $keep = grep { $_ eq '--keep' } @ARGV;
my $home = $ENV{HOME};
my $id = 'demo-task-board-0000-0000-000000000000';
my $dir = "$home/.claude/projects/-demo-task-board";
my $main = "$dir/$id.jsonl";
my $subDir = "$dir/$id/subagents";
make_path($subDir);
my $J = JSON::PP->new->utf8;

sub iso { strftime('%Y-%m-%dT%H:%M:%S', gmtime(time())) . '.000Z' }
package Raw { sub new { my ($c, $s) = @_; bless \$s, $c } }
sub val { my ($v) = @_; return $$v if ref $v eq 'Raw'; return '[' . join(',', map { val($_) } @$v) . ']' if ref $v eq 'ARRAY'; return $J->encode([$v]) =~ s/^\[|\]$//gr }
sub obj { my @p = @_; return Raw->new('{}') if !@p; Raw->new('{' . join(',', map { val('' . $p[$_ * 2]) . ':' . val($p[$_ * 2 + 1]) } 0 .. $#p / 2) . '}') }
sub append { my ($p, @lines) = @_; open(my $fh, '>>:raw', $p) or die; print $fh map { ${ ref $_ ? $_ : obj(@$_) } . "\n" } @lines; close $fh }
my $n = 0;
sub assistant {
  my (%o) = @_;
  $n++;
  obj(parentUuid => 'p', isSidechain => JSON::PP::false,
    message => obj(model => $o{model} // 'claude-opus-5-5', id => "msg_demo_$n", type => 'message', role => 'assistant', content => $o{content},
      stop_reason => $o{stop} // 'tool_use',
      usage => obj(input_tokens => 20, cache_creation_input_tokens => 1500, cache_read_input_tokens => 42000, output_tokens => 300)),
    effort => 'high', type => 'assistant', uuid => "u$n", timestamp => iso(), cwd => '/Users/demo/demo-project');
}
sub tool { my ($name, $input) = @_; obj(type => 'tool_use', id => 'tu' . (++$n), name => $name, input => $input) }

# 清单：三个阶段
my @tasks = ('Survey: Read release notes', 'Survey: Probe the schema', 'Renumber: Set level prefix', 'Renumber: Renumber 14 files', 'Export: Write the PDF', 'Export: Verify PDF');

open(my $fh, '>:raw', $main); close $fh;
append($main, obj(type => 'custom-title', customTitle => '演示：整理发布说明（模拟）', sessionId => $id));
append($main, obj(parentUuid => undef, isSidechain => JSON::PP::false, type => 'user', message => obj(role => 'user', content => '整理发布说明'),
  uuid => 'h1', timestamp => iso(), cwd => '/Users/demo/demo-project', origin => obj(kind => 'human')));
append($main, assistant(content => [ map { tool('TaskCreate', obj(subject => $_)) } @tasks ]));

my @agents = (
  [0, 'Explore', 'old notes', 'claude-haiku-4-5-20251001', 'Grep'],
  [1, 'general-purpose', 'schema probe', 'claude-sonnet-5-5', 'Bash'],
  [3, 'Explore', 'level map', 'claude-haiku-4-5-20251001', 'Read'],
  [3, 'general-purpose', 'renumber batch', 'claude-opus-5-5', 'Edit'],
  [4, 'general-purpose', 'sheet writer', 'claude-sonnet-5-5', 'Write'],
);
my %subFile;
sub start_agent {
  my ($k, $i) = @_;
  my ($step, $type, $desc, $model, $toolName) = @{ $agents[$k] };
  my $f = "$subDir/agent-demo$k.jsonl";
  $subFile{$k} = $f;
  open(my $w, '>:raw', "$subDir/agent-demo$k.meta.json"); print $w $J->encode({ agentType => $type, description => $desc }); close $w;
  open(my $o, '>:raw', $f); close $o;
  append($f, obj(type => 'user', message => obj(role => 'user', content => $desc), uuid => 's0', timestamp => iso()));
  append($f, assistant(model => $model, content => [ tool($toolName, obj()), tool($toolName, obj()) ]));
}
sub tick_agent { my ($k) = @_; my $f = $subFile{$k} or return; append($f, assistant(model => $agents[$k][3], content => [ tool($agents[$k][4], obj()) ])) }
sub end_agent { my ($k) = @_; my $f = delete $subFile{$k} or return; append($f, assistant(model => $agents[$k][3], stop => 'end_turn', content => [ obj(type => 'text', text => 'done') ])) }

my $STEP = 25;   # 每步大约几秒
for my $i (0 .. $#tasks) {
  append($main, assistant(content => [ tool('TaskUpdate', obj(taskId => '' . ($i + 1), status => 'in_progress')) ]));
  for my $k (0 .. $#agents) { start_agent($k, $i) if $agents[$k][0] == $i }
  for (1 .. int($STEP / 5)) { sleep 5; tick_agent($_) for keys %subFile; append($main, assistant(content => [ tool('Bash', obj(command => 'ls')) ])) }
  for my $k (keys %subFile) { end_agent($k) if $agents[$k][0] == $i && $k != 1 }   # k=1 的 schema probe 跨两步才结束
  end_agent(1) if $i == 2;
  append($main, assistant(content => [ tool('TaskUpdate', obj(taskId => '' . ($i + 1), status => 'completed')) ]));
}
append($main, assistant(stop => 'end_turn', content => [ obj(type => 'text', text => '全部完成') ]));
sleep 40;
remove_tree($dir) unless $keep;
