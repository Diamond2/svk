package SVK::Command::Copy;
use strict;
use SVK::Version;  our $VERSION = $SVK::VERSION;
use base qw( SVK::Command::Mkdir );
use SVK::Util qw( get_anchor get_prompt abs2rel splitdir );
use SVK::I18N;

sub options {
    ($_[0]->SUPER::options,
     'r|revision=i' => 'rev');
}

sub parse_arg {
    my ($self, @arg) = @_;
    return if @arg < 1;

    push @arg, '' if @arg == 1;

    my $dst = pop(@arg);
    my @src = (map {$self->arg_co_maybe ($_)} @arg);

    if ( my $target = eval { $self->arg_co_maybe ($dst) }) {
        $dst = $target;
    }
    else {
        # Asking the user for copy destination.
        # In this case, first magically promote ourselves to "cp -p".
        # (otherwise it hurts when user types //deep/directory/name)
        $self->{parent} = 1;

        # -- make a sane default here for mirroring --
        my $default = undef;
        if (@src == 1 and $src[0]->path =~ m{/mirror/([^/]+)$}) {
            $default = "/" . $src[0]->depotname . "/$1";
        }

        my $path = $self->prompt_depotpath("copy", $default);

        if ($dst =~ /^\.?$/) {
            $self->{_checkout_path} = (splitdir($path))[-1];
        }
        else {
            $self->{_checkout_path} = $dst;
        }

        $dst = $self->arg_depotpath("$path/");
    }

    return (@src, $dst);
}

sub lock {
    my $self = shift;
    $self->lock_target ($_[-1]);
}

sub handle_co_item {
    my ($self, $src, $dst) = @_;
    $src->as_depotpath;
    my $xdroot = $dst->root ($self->{xd});
    die loc ("Path %1 does not exist.\n", $src->{path})
	if $src->root->check_path ($src->{path}) == $SVN::Node::none;
    my ($copath, $report) = @{$dst}{qw/copath report/};
    die loc ("Path %1 already exists.\n", $copath)
	if -e $copath;
    my $entry = $self->{xd}{checkout}->get ($copath);
    $src->normalize;
    $src->anchorify; $dst->anchorify;
    # if SVK::Merge could take src being copath to do checkout_delta
    # then we have 'svk cp copath... copath' for free.
    SVK::Merge->new (%$self, repos => $dst->{repos}, nodelay => 1,
		     report => $report,
		     base => $src->new (path => '/', revision => 0),
		     src => $src, dst => $dst)->run ($self->get_editor ($dst));

    $self->{xd}{checkout}->store_recursively ($copath, {'.schedule' => undef,
							'.newprop' => undef});
    # XXX: can the scheudle be something other than delete ?
    $self->{xd}{checkout}->store ($copath, {'.schedule' => $entry->{'.schedule'} ? 'replace' : 'add',
					    scheduleanchor => $copath,
					    '.copyfrom' => $src->path,
					    '.copyfrom_rev' => $src->{revision}});
}

sub handle_direct_item {
    my ($self, $editor, $anchor, $m, $src, $dst) = @_;
    $src->normalize;
    my ($path, $rev) = @{$src}{qw/path revision/};
    if ($m) {
	$path =~ s/^\Q$m->{target_path}\E/$m->{source}/;
	$rev = $m->find_remote_rev ($rev)
	    or die "Can't find remote revision of for $path";
    }
    else {
	$path = "file://$src->{repospath}$path";
    }
    $editor->close_directory
	($editor->add_directory (abs2rel ($dst->path, $anchor => undef, '/'), 0, $path, $rev));
    $self->adjust_anchor ($editor);
}

sub _unmodified {
    my ($self, $target) = @_;
    # Use condensed to do proper anchorification.
    $target = $self->arg_condensed ($target->copath);
    $self->{xd}->checkout_delta
	( %$target,
	  xdroot => $target->root ($self->{xd}),
	  editor => SVK::Editor::Status->new
	  ( notify => SVK::Notify->new
	    ( cb_flush => sub {
		  die loc ("%1 is modified.\n", $target->copath ($_[0]));
	      })),
	  # need tests: only useful for move killing the src with unknown entries
	  cb_unknown => sub {
	      die loc ("%1 is missing.\n", $target->copath ($_[0]))});
}

sub check_src {
    my ($self, @src) = @_;
    for my $src (@src) {
	# XXX: respect copath rev
	$src->{revision} = $self->{rev} if defined $self->{rev};
	next unless $src->{copath};
	$self->_unmodified ($src->new);
    }
}

sub run {
    my ($self, @src) = @_;
    my $dst = pop @src;
    return loc("Different depots.\n") unless $dst->same_repos (@src);
    my $m = $self->under_mirror ($dst);
    return "Different sources.\n"
	if $m && !$dst->same_source (@src);
    $self->check_src (@src);
    # XXX: check dst to see if the copy is obstructured or missing parent
    my $fs = $dst->{repos}->fs;
    if ($dst->{copath}) {
	# XXX: check if dst is versioned
	return loc("%1 is not a directory.\n", $dst->{copath})
	    if $#src > 0 && !-d $dst->{copath};
	my @cpdst;
	for (@src) {
	    my $cpdst = $dst->new;
	    $cpdst->descend ($_->{path} =~ m|/([^/]+)/?$|)
		if -d $cpdst->{copath};
	    die loc ("Path %1 already exists.\n", $cpdst->{report})
		if -e $cpdst->{copath};
	    push @cpdst, $cpdst;
	}
	$self->handle_co_item ($_, shift @cpdst) for @src;
    }
    else {
	my $root = $dst->root;
	if ($root->check_path ($dst->{path}) != $SVN::Node::dir) {
	    die loc ("Copying more than one source requires %1 to be directory.\n", $dst->{report})
		if $#src > 0;
	    $dst->anchorify;
	}
	$self->get_commit_message ();
	my ($anchor, $editor) = $self->get_dynamic_editor ($dst);
	for (@src) {
	    $self->handle_direct_item ($editor, $anchor, $m, $_,
				       $dst->{targets} ? $dst :
				       $dst->new (targets => [$_->{path} =~ m|/([^/]+)/?$|]));
	}
	$self->finalize_dynamic_editor ($editor);
    }

    if (defined( my $copath = $self->{_checkout_path} )) {
        my $checkout = $self->command ('checkout');
	$checkout->getopt ([]);
        my @arg = $checkout->parse_arg ($dst->{report}, $copath);
        $checkout->lock (@arg);
        $checkout->run (@arg);
    }

    return;
}

1;

__DATA__

=head1 NAME

SVK::Command::Copy - Make a versioned copy

=head1 SYNOPSIS

 copy DEPOTPATH1 DEPOTPATH2
 copy DEPOTPATH [PATH]

=head1 OPTIONS

 -r [--revision] arg    : act on revision ARG instead of the head revision
 -m [--message] arg     : specify commit message ARG
 -p [--parent]          : create intermediate directories as required
 -P [--patch] arg       : instead of commit, save this change as a patch
 -C [--check-only]      : try operation but make no changes
 -S [--sign]            : sign this change

=head1 AUTHORS

Chia-liang Kao E<lt>clkao@clkao.orgE<gt>

=head1 COPYRIGHT

Copyright 2003-2005 by Chia-liang Kao E<lt>clkao@clkao.orgE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
