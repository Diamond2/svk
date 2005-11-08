package SVK::Path;
use strict;
use SVK::Version;  our $VERSION = $SVK::VERSION;
use SVK::I18N;
use autouse 'SVK::Util' => qw( get_anchor catfile abs2rel HAS_SVN_MIRROR 
			       IS_WIN32 find_prev_copy get_depot_anchor );
use base 'Class::Accessor::Fast';
__PACKAGE__->mk_accessors(qw(repos path depotname revision));

=head1 NAME

SVK::Path - SVK path class

=head1 SYNOPSIS

 See below

=head1 DESCRIPTION

The class represents a node in svk depot.

=cut

sub new {
    my ($class, @arg) = @_;
    my $self = ref $class ? $class->_clone :
	bless {}, $class;
    %$self = (%$self, @arg);
    $self->refresh_revision unless defined $self->revision;
    if (defined $self->{copath}) {
	require SVK::Path::Checkout;
	bless $self, 'SVK::Path::Checkout';
    }
    if (my $depotpath = delete $self->{depotpath}) {
	$self->depotname($depotpath =~ m!^/([^/]*)!);
    }
    return $self;
}

sub refresh_revision {
    my ($self) = @_;
    $self->revision($self->repos->fs->youngest_rev);
}

sub _clone {
    my ($self) = @_;

    require Clone;
    my $xd = delete $self->{xd};
    my $cloned = Clone::clone ($self);
    $cloned->repos($self->repos);
    $self->{xd} = $cloned->{xd} = $xd if $xd;
    return $cloned;
}

sub root {
    my $self = shift;
    return SVK::XD::Root->new($self->repos->fs->revision_root
			      ($self->revision));
}

sub report { Carp::cluck if defined $_[1]; $_[0]->depotpath }

=head2 same_repos

Returns true if all C<@other> targets are from the same repository

=cut

sub same_repos {
    my ($self, @other) = @_;
    for (@other) {
	return 0 if $self->repos ne $_->repos;
    }
    return 1;
}

=head2 same_source

Returns true if all C<@other> targets are mirrored from the same source

=cut

sub same_source {
    my ($self, @other) = @_;
    return 0 unless HAS_SVN_MIRROR;
    return 0 unless $self->same_repos (@other);
    my $mself = SVN::Mirror::is_mirrored ($self->repos, $self->path);
    for (@other) {
	my $m = SVN::Mirror::is_mirrored ($_->repos, $_->path);
	return 0 if $m xor $mself;
	return 0 if $m && $m->{target_path} ne $m->{target_path};
    }
    return 1;
}

sub _to_pclass {
    my ($self, $path, $what) = @_;
    $what = 'Unix' if !defined $what && !$self->isa('SVK::Path::Checkout');
    return $what ? Path::Class::foreign_dir($what, $path) : Path::Class::dir($path);
}

sub anchorify {
    my ($self) = @_;
    my $targets = delete $self->{targets};
    ($self->{path}, $self->{targets}[0]) = get_depot_anchor(1, $self->{path});
    $self->{targets} = [map {"$self->{targets}[0]/$_"} @$targets]
	if $targets && @$targets;
}

=head2 normalize

Normalize the revision to the last changed one.

=cut

sub normalize {
    my ($self) = @_;
    my $fs = $self->repos->fs;
    my $root = $fs->revision_root($self->revision);
    $self->revision( ($root->node_history ($self->path)->prev(0)->location)[1] )
	unless $self->revision == $root->node_created_rev ($self->path);
}

=head2 as_depotpath

Makes target depotpath. Takes C<$revision> number optionally.

=cut

sub as_depotpath {
    my ($self, $revision) = @_;
    delete $self->{copath};
    $self->revision($revision) if defined $revision;
    bless $self, 'SVK::Path';
    return $self;
}

=head2 path

Returns the full path of the target even if anchorified.

=cut

sub path {
    my ($self) = @_;
    (exists $self->{targets} && defined $self->{targets}[0])
	? $self->_to_pclass($self->{path}, 'Unix')->subdir($self->{targets}[0])->stringify : $self->{path};
}

=head2 descend

Makes target descend into C<$entry>

=cut

sub descend {
    my ($self, $entry) = @_;
    $self->{path} .= "/$entry";
    return $self;
}

=head2 universal

Returns corresponding L<SVK::Target::Universal> object.

=cut

sub universal {
    SVK::Target::Universal->new ($_[0]);
}

sub contains_mirror {
    require SVN::Mirror;
    my ($self) = @_;
    my $path = $self->{path};
    $path .= '/' unless $path eq '/';
    return map { substr ("$_/", 0, length($path)) eq $path ? $_ : () }
	SVN::Mirror::list_mirror ($self->repos);
}

=head2 depotpath

Returns depotpath of the target

=cut

sub depotpath {
    my $self = shift;

    return '/'.$self->depotname.$self->{path};
}

# depotpath only for now
# cache revprop:
# svk:copy_cache

# svk:copy_cache_prev points to the revision in the depot that the
# previous copy happens.

sub copy_ancestors {
    my $self = shift;
    @{ $self->{copy_ancesotrs}{$self->path}{$self->revision} ||=
	   [$self->_copy_ancestors] };
}

sub _copy_ancestors {
    my $self = shift;
    my $fs = $self->repos->fs;
    my $t = $self->new->as_depotpath;
    my @result;
    my ($old_pool, $new_pool) = (SVN::Pool->new, SVN::Pool->new);
    my ($root, $path) = ($t->root, $t->path);
    while (my (undef, $copyfrom_root, $copyfrom_path) = nearest_copy ($root, $path, $new_pool)) {
	push @result, [$copyfrom_path,
		       $copyfrom_root->revision_root_revision];
	($root, $path) = ($copyfrom_root, $copyfrom_path);

	$old_pool->clear;
	($old_pool, $new_pool) = ($new_pool, $old_pool);
    }
    return @result;
}

=head2 nearest_copy(root, path, [pool])

given a root object (or a target) and a path, returns the revision
root where it's ancestor is from another path, and ancestor's root and
path.

=cut

*nearest_copy = SVN::Fs->can('closest_copy')
  ? *_nearest_copy_svn : *_nearest_copy_svk;

sub _nearest_copy_svn {
    my ($root, $path, $ppool) = @_;
    if ($root->isa(__PACKAGE__)) {
        ($root, $path) = ($root->root, $root->path);
    }
    my ($toroot, $topath) = $root->closest_copy($path, $ppool);
    return unless $toroot;

    my $pool = SVN::Pool->new_default;
    my ($copyfrom_rev, $copyfrom_path) = $toroot->copied_from ($topath);
    $path =~ s/^\Q$topath\E/$copyfrom_path/;
    my $copyfrom_root = $root->fs->revision_root( $copyfrom_rev );
    # If the path doesn't exist in copyfrom_root, it's newly created one in toroot
    return unless $copyfrom_root->check_path( $path );

    $copyfrom_rev = ($copyfrom_root->node_history ($path)->prev(0)->location)[1]
        unless $copyfrom_rev == $copyfrom_root->node_created_rev ($path);
    $copyfrom_root = $root->fs->revision_root($copyfrom_rev, $ppool)
	unless $copyfrom_root->revision_root_revision == $copyfrom_rev;

    return ($toroot, $root->fs->revision_root($copyfrom_rev, $ppool), $path);
}

sub _nearest_copy_svk {
    my ($root, $path, $ppool) = @_;
    if (ref ($root) eq __PACKAGE__) {
	($root, $path) = ($root->root, $root->path);
    }
    my $fs = $root->fs;
    my $spool = SVN::Pool->new_default;
    my ($old_pool, $new_pool) = (SVN::Pool->new, SVN::Pool->new);

    # normalize
    my $hist = $root->node_history ($path)->prev(0);
    my $rev = ($hist->location)[1];
    $root = $fs->revision_root ($rev, $ppool);

    while ($hist = $hist->prev(1, $new_pool)) {
	# Find history_prev revision, if the path is different, bingo.
	my ($hppath, $hprev) = $hist->location;
	if ($hppath ne $path) {
	    $hist = $root->node_history ($path, $new_pool)->prev(0);
	    my $rev = ($hist->location($new_pool))[1];
	    $root = $fs->revision_root ($rev, $ppool);
	    return ($root, $fs->revision_root ($hprev, $ppool), $hppath);
	}

	# Find nearest copy of the current revision (up to but *not*
	# including the revision itself). If the copy contains us, bingo.
	my $copy;
	($root, $copy) = find_prev_copy ($fs, $hprev, $new_pool) or last; # no more copies
	$rev = $root->revision_root_revision;
	if (my ($fromrev, $frompath) = _copies_contain_path ($copy, $path)) {
	    # there were copy, but the descendent might not exist there
	    my $proot = $fs->revision_root ($fromrev, $ppool);
	    last unless $proot->check_path ($frompath, $old_pool);
	    return ($fs->revision_root($root->revision_root_revision, $ppool),
		    $proot, $frompath);
	}

	if ($rev < $hprev) {
	    # Reset the hprev root to this earlier revision to avoid infinite looping
	    local $@;
	    $hist = eval { $root->node_history ($path, $new_pool)->prev(0, $new_pool) } or last;
	}
        $old_pool->clear;
	$spool->clear;
        ($old_pool, $new_pool) = ($new_pool, $old_pool);
    }
    return;
}

sub _copies_contain_path {
    my ($copy, $path) = @_;
    my ($match) = grep { index ("$path/", "$_/") == 0 }
	sort { length $b <=> length $a } keys %$copy;
    return unless $match;
    $path =~ s/^\Q$match\E/$copy->{$match}[1]/;
    return ($copy->{$match}[0], $path);
}

=head2 related_to

Check if C<$self> is related to another target.

=cut

sub related_to {
    my ($self, $other) = @_;
    # XXX: when two related paths are mirrored separatedly, need to
    # use hooks or merge tickets to decide if they are related.
    return SVN::Fs::check_related
	($self->root->node_id ($self->path),
	 $other->root->node_id ($other->path));
}

=head2 copied_from ($want_mirror)

Return the nearest copy target that still exists.  If $want_mirror is true,
only return one that was mirrored from somewhere.

=cut

sub copied_from {
    my ($self, $want_mirror) = @_;

    my $target = $self->new;
    $target->{report} = '';
    $target->as_depotpath;

    my $root = $target->root;
    my $fromroot;
    while ((undef, $fromroot, $target->{path}) = $target->nearest_copy) {
	$target->revision($fromroot->revision_root_revision);
	# Check for existence.
	if ($root->check_path ($target->{path}) == $SVN::Node::none) {
	    next;
	}

	# Check for mirroredness.
	if ($want_mirror and HAS_SVN_MIRROR) {
	    my ($m, $mpath) = SVN::Mirror::is_mirrored (
		$target->repos, $target->{path}
	    );
	    $m->{source} or next;
	}

	# It works!  Let's update it to the latest revision and return
	# it as a fresh depot path.
	$target->refresh_revision;
	$target->as_depotpath;

	delete $target->{targets};
	return $target;
    }

    return undef;
}

sub search_revision {
    my ($self, %arg) = @_;
    my $root = $self->root;
    my @rev = ($arg{start} || 1, $self->revision);
    my $id = $root->node_id($self->path);
    my $pool = SVN::Pool->new_default;

    while ($rev[0] <= $rev[1]) {
	$pool->clear;
	my $rev = int(($rev[0]+$rev[1])/2);
	my $search_root = $self->new(revision => $rev)->root;
	if ($search_root->check_path($self->path) &&
	    SVN::Fs::check_related($id, $search_root->node_id($self->path))) {

	    # normalise
	    my $nrev = $rev;
	    $nrev = ($search_root->node_history($self->path)->prev(0)->location)[1]
		unless $rev[0] == $rev[1] ||
		    $nrev == $search_root->node_created_rev ($self->path);
	    my $cmp = $arg{cmp}->($nrev);

	    return $nrev if $cmp == 0;

	    if ($cmp < 0) {
		$rev[0] = $rev+1;
	    }
	    else {
		$rev[1] = $rev-1;
	    }
	}
	else {
	    $rev[0] = $rev+1;
	}
    }
    return;
}

# $path is the actul path we use to normalise
sub merged_from {
    my ($self, $src, $merge, $path) = @_;
    $self = $self->new->as_depotpath;
    my $usrc = $src->universal;
    my $srckey = join(':', $usrc->{uuid}, $usrc->{path});
    warn "trying to look for the revision on $self->{path} that was merged from $srckey\@$src->{revision} at $path" if $main::DEBUG;

    my %copies = map { join(':', $_->{uuid}, $_->{path}) => $_ }
	$merge->copy_ancestors($self);

    $self->search_revision
	( cmp => sub {
	      my $rev = shift;
	      warn "==> look at $rev" if $main::DEBUG;
	      my $search = $self->new(revision => $rev);
	      my $minfo = { %copies,
			    %{$merge->merge_info($search)} };

#$merge->merge_info_with_copy($search);
	      return -1 unless $minfo->{$srckey};
	      # get the actual revision of the on the merge target,
	      # and compare
	      my $msrc = $self->new
		  ( path => $path,
		    revision => $minfo->{$srckey}->
		    local($self->repos)->revision );
	      { local $@;
	        eval { $msrc->normalize } or return -1;
	      }

	      if ($msrc->revision > $src->revision) {
		  return 1;
	      }
	      elsif ($msrc->revision < $src->revision) {
		  return -1;
	      }

	      my $prev;
	      { local $@; 
	        $prev = eval { ($search->root->node_history($self->path)->prev(0)->prev(0)->location)[1] } or return 0;
	      }

	      # see if prev got different merge info about srckey.
	      warn "==> to compare with $prev" if $main::DEBUG;
	      my $uret = $merge->merge_info_with_copy
		  ($self->new(revision => $prev))->{$srckey}
		      or return 0;

	      return ($uret->local($self->repos)->revision == $src->revision)
		? 1 : 0;
	  } );
}

=head1 SEE ALSO

L<SVK::Path::Checkout>

=head1 AUTHORS

Chia-liang Kao E<lt>clkao@clkao.orgE<gt>

=head1 COPYRIGHT

Copyright 2003-2005 by Chia-liang Kao E<lt>clkao@clkao.orgE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut

1;