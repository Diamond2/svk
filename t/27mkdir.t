#!/usr/bin/perl -w
use strict;
BEGIN { require 't/tree.pl' };
use Test::More tests => 16;

our $output;
my ($xd, $svk) = build_test('test');
my ($copath, $corpath) = get_copath ('mkdir');
my ($repospath, $path, $repos) = $xd->find_repos ('/test/', 1);
$svk->checkout ('//', $copath);
is_output_like ($svk, 'mkdir', [], qr'SYNOPSIS', 'mkdir - help');
is_output_like ($svk, 'mkdir', ['nonexist'],
		qr'not a depot path');

# XXX: fix the strange suggestion in message
is_output ($svk, 'mkdir', ['-m', 'msg', '//'],
	   [qr'Item already exists',
	    'Please update checkout first.']);

is_output ($svk, 'mkdir', ['-m', 'msg', '//newdir'],
	   ['Committed revision 1.']);

is_output ($svk, 'mkdir', ['-m', 'msg', '//i-newdir/deep'],
	   [qr'.*',
	    'Please update checkout first.']);

is_output ($svk, 'mkdir', ['-p', '-m', 'msg', '//i-newdir/deep'],
	   ['Committed revision 2.']);

is_output ($svk, 'mkdir', ['-p', '-m', 'msg', '//i-newdir/deeper/file'],
	   ['Committed revision 3.']);

is_output ($svk, 'mkdir', ["$copath/c-newfile"],
      [__"A   $copath/c-newfile"]);

is_output ($svk, 'mkdir', ["$copath/c-newdir/deeper"],
      ["$copath/c-newdir/deeper is not a depot path."]);

is_output ($svk, 'mkdir', ['-p', "$copath/c-newdir/deeper"],
      [__"A   $copath/c-newdir",
       __"A   $copath/c-newdir/deeper"]);

is_output ($svk, 'mkdir', ['-p', "foo bar"],
     [__"A   foo",
      __"A   bar"]);

is_ouput ($svk, 'mkdir', ['-p', "d-newdir/foo e-newdir"],
     [__"A   d-newdir",
      __"A   d-newdir/foo",
      __"A   e-newdir"]);

SKIP: {
skip 'SVN::Mirror not installed', 4
    unless HAS_SVN_MIRROR;

my $uri = uri($repospath);

$svk->mirror ('//m', $uri.($path eq '/' ? '' : $path));
$svk->sync ('//m');

is_output ($svk, 'mkdir', ['-m', 'msg', '//m/dir-on-source'],
	   ["Merging back to mirror source $uri.",
	    'Merge back committed as revision 1.',
	    "Syncing $uri",
	    'Retrieving log information from 1 to 1',
	    'Committed revision 5 from revision 1.']);

is_output ($svk, 'mkdir', ['-m', 'msg', '//m/source/deep'],
	   ["Merging back to mirror source $uri.",
	    qr'.*',
	    'Please sync mirrored path /m first.']);

is_output ($svk, 'mkdir', ['-p', '-m', 'msg', '//m/source/deep'],
	   ["Merging back to mirror source $uri.",
	    'Merge back committed as revision 2.',
	    "Syncing $uri",
	    'Retrieving log information from 2 to 2',
	    'Committed revision 6 from revision 2.']);

is_output ($svk, 'mkdir', ['-p', '-m', 'msg', '//m/source/deep'],
	   ["Merging back to mirror source $uri.",
	    qr'Item already exists',
	    'Please sync mirrored path /m first.']);

}
