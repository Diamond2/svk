#!/usr/bin/perl -w
use strict;
BEGIN { require 't/tree.pl' };
plan_svm tests => 3;

our ($output, $answer);
# build another tree to which we want to mirror ourselves.
my ($xd, $svk) = build_test('svm-empty', 'real-empty');
my ($copath, $corpath) = get_copath ('svm-empty');

$svk->mkdir ('-m', 'remote trunk', '/svm-empty/trunk');
$svk->ps ('-m', 'foo', 'bar' => 'baz', '/svm-empty/trunk');
$svk->mkdir ('-m', 'this is the local tree', '//local');
waste_rev ($svk, '//local/tree');

my ($drepospath, $dpath, $drepos) = $xd->find_repos ('/svm-empty/trunk', 1);
my $uri = uri($drepospath);
$svk->mirror ('//remote', $uri.($dpath eq '/' ? '' : $dpath));

$svk->sync ('//remote');
my ($srepospath, $spath, $srepos) = $xd->find_repos ('//remote', 1);
my $old_srev = $srepos->fs->youngest_rev;
$svk->sync ('//remote');
$svk->sync ('//remote');
$svk->sync ('//remote');
is ($srepos->fs->youngest_rev, $old_srev, 'sync is idempotent');

$svk->smerge ('-IB', '//local', '//remote');
$svk->smerge ('-IB', '//local', '//remote');
is ($drepos->fs->youngest_rev, 4, 'smerge -IB is idempotent');

my ($repospath, $path, $repos) = $xd->find_repos ('/real-empty/', 1);
$uri = uri($repospath);
$answer = ['', 'empty', ''];
$svk->cp (-m => 'branch empty repository', $uri, '//test');

$svk->co ('//test', $copath);
chdir ($copath);
is_output ($svk, 'push', [],
	   ["Auto-merging (0, 10) /test to /mirror/empty (base /mirror/empty:0).",
	    'Empty merge.']);
