package SVK::Command::Update;
use strict;
our $VERSION = $SVK::VERSION;

use base qw( SVK::Command );
use SVK::XD;
use SVK::I18N;

sub options {
    ('r|revision=i'    => 'rev',
     'N|non-recursive' => 'nonrecursive',
     's|sync'          => 'sync',
     'm|merge'         => 'merge');
}

sub parse_arg {
    my ($self, @arg) = @_;
    @arg = ('') if $#arg < 0;
    return map {$self->arg_copath ($_)} @arg;
}

sub lock {
    my ($self, @arg) = @_;
    $self->lock_target ($_) for @arg;
}

sub run {
    my ($self, @arg) = @_;

    for my $target (@arg) {
	my $update_target = SVK::Target->new
	    ( %$target,
	      path => $self->{update_target_path} || $target->{path},
	      revision => defined $self->{rev} ?
	      $self->{rev} : $target->{repos}->fs->youngest_rev,
	      copath => undef
	    );

        my $sync_target = (
            $self->{merge} ? $update_target->copied_from : $update_target
        );

        if ($self->{sync}) {
            require SVK::Command::Sync;
            my $sync = SVK::Command::Sync->new;
            %$sync = (%$self, %$sync);
            $sync->run($sync_target);
            $sync_target->refresh_revision;
        }

        if ($self->{merge}) {
            require SVK::Command::Smerge;
            my $smerge = SVK::Command::Smerge->new;
            %$smerge = ( message => '', log => 1, %$self, %$smerge, sync => 0);
            $smerge->run($sync_target => $update_target);
            $update_target->refresh_revision;
        }

	$self->do_update ($target, $update_target);
    }
    return;
}

sub do_update {
    my ($self, $cotarget, $update_target) = @_;
    my ($xdroot, $newroot) = map { $_->root ($self->{xd}) } ($cotarget, $update_target);
    # unanchorified
    my ($path, $copath) = @{$cotarget}{qw/path copath/};
    my $report = $cotarget->{report};
    my $kind = $newroot->check_path ($update_target->{path});
    die loc("path %1 does not exist.\n", $update_target->{path})
	if $kind == $SVN::Node::none;

    print loc("Syncing %1(%2) in %3 to %4.\n", @{$cotarget}{qw( depotpath path copath )},
	      $update_target->{revision});
    if ($kind == $SVN::Node::file ) {
	$cotarget->anchorify;
	$update_target->anchorify;
	# can't use $cotarget->{path} directly since the (rev0, /) hack
	($path, $copath) = @{$cotarget}{qw/path copath/};
	$cotarget->{targets}[0] = $cotarget->{copath_target};
    }
    my $base = $cotarget;
    $base = $base->new (path => '/')
	if $xdroot->check_path ($base->path) == $SVN::Node::none;
    mkdir ($cotarget->{copath}) or die $!
	unless $self->{check_only} || -e $cotarget->{copath};

    my $notify = SVK::Notify->new_with_report
	($report, $cotarget->{targets}[0], 1);
    my $merge = SVK::Merge->new
	(repos => $cotarget->{repos}, base => $base, base_root => $xdroot,
	 no_recurse => $self->{nonrecursive}, notify => $notify, nodelay => 1,
	 src => $update_target, dst => $cotarget,
	 xd => $self->{xd}, check_only => $self->{check_only});
    $merge->run ($self->{xd}->get_editor (copath => $copath, path => $path,
					  ignore_checksum => 1,
					  oldroot => $xdroot, newroot => $newroot,
					  revision => $update_target->{revision},
					  anchor => $cotarget->{path},
					  target => $cotarget->{targets}[0] || '',
					  update => 1, check_only => $self->{check_only}));
}

1;

__DATA__

=head1 NAME

SVK::Command::Update - Bring changes from repository to checkout copies

=head1 SYNOPSIS

 update [PATH...]

=head1 OPTIONS

 -r [--revision] arg    : act on revision ARG instead of the head revision
 -N [--non-recursive]   : do not descend recursively
 -s [--sync]            : synchronize mirrored sources before update
 -m [--merge]           : star merge from copied sources before update

=head1 DESCRIPTION

Synchronize checkout copies to revision given by -r or to HEAD
revision by default.

For each updated item a line will start with a character reporting the
action taken. These characters have the following meaning:

  A  Added
  D  Deleted
  U  Updated
  C  Conflict
  G  Merged
  g  Merged without actual change

A character in the first column signifies an update to the actual
file, while updates to the file's props are shown in the second
column.

If both C<--sync> and C<--merge> are specified, like in C<svk up -sm>,
it will first synchronize the mirrored copy source path, and then smerge
from it.

=head1 AUTHORS

Chia-liang Kao E<lt>clkao@clkao.orgE<gt>

=head1 COPYRIGHT

Copyright 2003-2004 by Chia-liang Kao E<lt>clkao@clkao.orgE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
