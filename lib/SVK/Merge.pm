package SVK::Merge;
use strict;
use SVK::Util qw (find_svm_source svn_mirror);
use SVK::I18N;

sub new {
    my ($class, @arg) = @_;
    my $self = bless {}, $class;
    %$self = @arg;
    return $self;
}

sub find_merge_base {
    my ($self, $repos, $src, $dst) = @_;
    my $srcinfo = $self->find_merge_sources ($repos, $src);
    my $dstinfo = $self->find_merge_sources ($repos, $dst);
    my ($basepath, $baserev);

    for (
	grep {exists $srcinfo->{$_} && exists $dstinfo->{$_}}
	(sort keys %{ { %$srcinfo, %$dstinfo } })
    ) {
	my ($path) = m/:(.*)$/;
	my $rev = $srcinfo->{$_} < $dstinfo->{$_} ? $srcinfo->{$_} : $dstinfo->{$_};
	# XXX: shuold compare revprop svn:date instead, for old dead branch being newly synced back
	if (!$basepath || $rev > $baserev) {
	    ($basepath, $baserev) = ($path, $rev);
	}
    }

    if (!$basepath) {
	die loc("Can't find merge base for %1 and %2\n", $src, $dst)
	  unless $self->{baseless} or $self->{base};

	my $fs = $repos->fs;
	my ($from_rev, $to_rev) = ($self->{base}, $repos->fs->youngest_rev);

	if (!$from_rev) {
	    # baseless merge
	    my $pool = SVN::Pool->new_default;
	    my $hist = $fs->revision_root($to_rev)->node_history($src);
	    do {
		$pool->clear;
		$from_rev = ($hist->location)[1];
	    } while $hist = $hist->prev(0);
	}

	return ($src, $from_rev, $to_rev);
    };

    return ($basepath, $baserev, $dstinfo->{$repos->fs->get_uuid.':'.$src} || $baserev);
}

sub find_merge_sources {
    my ($self, $repos, $path, $verbatim, $noself) = @_;
    my $pool = SVN::Pool->new_default;

    my $fs = $repos->fs;
    my $root = $fs->revision_root ($fs->youngest_rev);
    my $minfo = $root->node_prop ($path, 'svk:merge');
    my $myuuid = $fs->get_uuid ();
    if ($minfo) {
	$minfo = { map {my ($uuid, $path, $rev) = split ':', $_;
			my $m;
			($verbatim || ($uuid eq $myuuid)) ? ("$uuid:$path" => $rev) :
			    (svn_mirror && ($m = SVN::Mirror::has_local ($repos, "$uuid:$path"))) ?
				("$myuuid:$m->{target_path}" => $m->find_local_rev ($rev)) : ()
			    } split ("\n", $minfo) };
    }
    if ($verbatim) {
	my ($uuid, $path, $rev) = find_svm_source ($repos, $path);
	$minfo->{join(':', $uuid, $path)} = $rev
	    unless $noself;
	return $minfo;
    }
    else {
	$minfo->{join(':', $myuuid, $path)} = $fs->youngest_rev
	    unless $noself;
    }

    my %ancestors = $self->copy_ancestors ($repos, $path, $fs->youngest_rev, 1);
    for (sort keys %ancestors) {
	my $rev = $ancestors{$_};
	$minfo->{$_} = $rev
	    unless $minfo->{$_} && $minfo->{$_} > $rev;
    }

    return $minfo;
}

sub copy_ancestors {
    my ($self, $repos, $path, $rev, $nokeep) = @_;
    my $fs = $repos->fs;
    my $root = $fs->revision_root ($rev);
    $rev = $root->node_created_rev ($path);

    my $spool = SVN::Pool->new_default_sub;
    my ($found, $hitrev, $source) = (0, 0, '');
    my $myuuid = $fs->get_uuid ();
    my $hist = $root->node_history ($path);
    my ($hpath, $hrev);

    while ($hist = $hist->prev (1)) {
	$spool->clear;
	($hpath, $hrev) = $hist->location ();
	if ($hpath ne $path) {
	    $found = 1;
	}
	elsif (defined ($source = $fs->revision_prop ($hrev, "svk:copied_from:$path"))) {
	    $hitrev = $hrev;
	    last unless $source;
	    my $uuid;
	    ($uuid, $hpath, $hrev) = split ':', $source;
	    if ($uuid ne $myuuid) {
		my ($m, $mpath);
		if (svn_mirror &&
		    (($m, $mpath) = SVN::Mirror::has_local ($repos, "$uuid:$path"))) {
		    ($hpath, $hrev) = ($m->{target_path}, $m->find_local_rev ($hrev));
		    # XXX: WTF? need test suite for this
		    $hpath =~ s/\Q$mpath\E$//;
		}
		else {
		    return ();
		}
	    }
	    $found = 1;
	}
	last if $found;
    }

    $source = '' unless $found;
    if (!$found || $hitrev != $hrev) {
	$fs->change_rev_prop ($hitrev, "svk:copied_from:$path", undef)
	    unless $hitrev || $fs->revision_prop ($hitrev, "svk:copied_from_keep:$path");
	$source ||= join (':', $myuuid, $hpath, $hrev) if $found;
	if ($hitrev != $rev) {
	    $fs->change_rev_prop ($rev, "svk:copied_from:$path", $source);
	    $fs->change_rev_prop ($rev, "svk:copied_from_keep:$path", 'yes')
		unless $nokeep;
	}
    }
    return () unless $found;
    return ("$myuuid:$hpath" => $hrev, $self->copy_ancestors ($repos, $hpath, $hrev));
}

sub get_new_ticket {
    my ($self, $repos, $src, $dst) = @_;

    my $srcinfo = $self->find_merge_sources ($repos, $src, 1);
    my $dstinfo = $self->find_merge_sources ($repos, $dst, 1);
    my ($uuid, $newinfo);

    # bring merge history up to date as from source
    ($uuid, $dst) = find_svm_source ($repos, $dst);

    for (sort keys %{ { %$srcinfo, %$dstinfo } }) {
	next if $_ eq "$uuid:$dst";
	no warnings 'uninitialized';
	$newinfo->{$_} = $srcinfo->{$_} > $dstinfo->{$_} ? $srcinfo->{$_} : $dstinfo->{$_};
	print loc("New merge ticket: %1:%2\n", $_, $newinfo->{$_})
	    if !$dstinfo->{$_} || $newinfo->{$_} > $dstinfo->{$_};
    }

    return join ("\n", map {"$_:$newinfo->{$_}"} sort keys %$newinfo);
}

1;

