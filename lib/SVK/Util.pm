package SVK::Util;
use strict;
require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(md5 get_buffer_from_editor slurp_fh get_anchor get_prompt
		    find_svm_source resolve_svm_source svn_mirror tmpfile find_local_mirror);
our $VERSION   = '0.09';

use SVK::I18N;
use Digest::MD5 qw(md5_hex);
use File::Temp qw(mktemp);
my $svn_mirror = eval 'require SVN::Mirror; 1' ? 1 : 0;

sub svn_mirror { $svn_mirror }

sub get_prompt {
    my ($prompt, $regex) = @_;
    local $|;
    $|++;

    {
	print "$prompt";
	my $answer = <STDIN>;
	chomp $answer;
	redo if $regex and $answer !~ $regex;
	return $answer;
    }
}

sub md5 {
    my $fh = shift;
    my $ctx = Digest::MD5->new;
    $ctx->addfile($fh);
    return $ctx->hexdigest;
}

sub get_buffer_from_editor {
    my ($what, $sep, $content, $file, $anchor, $targets_ref) = @_;
    my $fh;
    if (defined $content) {
	($fh, $file) = tmpfile ($file, UNLINK => 0);
	print $fh $content;
	close $fh;
    }
    else {
	open $fh, $file;
	local $/;
	$content = <$fh>;
    }

    my $editor =	defined($ENV{SVN_EDITOR}) ? $ENV{SVN_EDITOR}
	   		: defined($ENV{EDITOR}) ? $ENV{EDITOR}
			: "vi"; # fall back to something
    my @editor = split (' ', $editor);
    while (1) {
	my $mtime = (stat($file))[9];
	print loc("Waiting for editor...\n");
	system (@editor, $file) and die loc("Aborted: %1\n", $!);
	last if (stat($file))[9] > $mtime;
	my $ans = get_prompt(
	    loc("%1 not modified: a)bort, e)dit, c)ommit?", $what),
	    qr/^[aec]/,
	);
	last if $ans =~ /^c/;
	die loc("Aborted.\n") if $ans =~ /^a/;
    }

    open $fh, $file;
    local $/;
    my @ret = defined $sep ? split (/\n\Q$sep\E\n/, <$fh>, 2) : (<$fh>);
    close $fh;
    unlink $file;
    return $ret[0] unless wantarray;

    my $old_targets = (split (/\n\Q$sep\E\n/, $content, 2))[1];
    my @new_targets = map [split(/\s+/, $_, 2)], grep /\S/, split(/\n+/, $ret[1]);
    if ($old_targets ne $ret[1]) {
	@$targets_ref = map $_->[1], @new_targets;
	s|^\Q$anchor\E/|| for @$targets_ref;
    }
    return ($ret[0], \@new_targets);
}

sub slurp_fh {
    my ($from, $to) = @_;
    local $/ = \16384;
    while (<$from>) {
	print $to $_;
    }
}

sub get_anchor {
    my $needtarget = shift;
    map {
	my (undef,$anchor,$target) = File::Spec->splitpath ($_);
	chop $anchor if length ($anchor) > 1;
	($anchor, $needtarget ? ($target) : ())
    } @_;
}

sub find_svm_source {
    my ($repos, $path, $rev) = @_;
    my $fs = $repos->fs;
    $rev ||= $fs->youngest_rev;
    my $root = $fs->revision_root ($rev);
    my ($uuid, $m, $mpath);

    if (svn_mirror) {
	($m, $mpath) = SVN::Mirror::is_mirrored ($repos, $path);
    }

    if ($m) {
	$path =~ s/\Q$mpath\E$//;
	$uuid = $root->node_prop ($path, 'svm:uuid');
	$path = $m->{source}.$mpath;
	$path =~ s/^\Q$m->{source_root}\E//;
	$path ||= '/';
	$rev = $m->{fromrev};
    }
    else {
	$uuid = $fs->get_uuid;
	$rev = ($root->node_history ($path)->prev (0)->location)[1];
    }

    return ($uuid, $path, $rev);
}

sub find_local_mirror {
    my ($repos, $uuid, $path, $rev) = @_;
    my $myuuid = $repos->fs->get_uuid;
    if ($uuid ne $myuuid && svn_mirror &&
	(my ($m, $mpath) = SVN::Mirror::has_local ($repos, "$uuid:$path"))) {
	return ("$m->{target_path}$mpath", $m->find_local_rev ($rev));
    }
    return;
}

sub resolve_svm_source {
    my ($repos, $uuid, $path) = @_;
    my $myuuid = $repos->fs->get_uuid;
    return ($path) if ($uuid eq $myuuid);
    return unless svn_mirror;
    my ($m, $mpath) = SVN::Mirror::has_local ($repos, "$uuid:$path");
    return unless $m;
    return ("$m->{target_path}$mpath", $m);
}

sub tmpfile {
    my ($temp, %args) = @_;
    my $dir = $ENV{TMPDIR} || '/tmp';
    $temp = "svk-${temp}XXXXX";
    return mktemp ("$dir/$temp") if exists $args{OPEN} && $args{OPEN} == 0;
    my $tmp = File::Temp->new ( TEMPLATE => $temp,
				DIR => $dir,
				SUFFIX => '.tmp',
				%args
			      );

    return wantarray ? ($tmp, $tmp->filename) : $tmp;
}

1;
