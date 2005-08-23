package SVK::Editor::Diff;
use strict;
use SVK::Version;  our $VERSION = $SVK::VERSION;

require SVN::Delta;
our @ISA = qw(SVN::Delta::Editor);

use SVK::I18N;
use autouse 'SVK::Util' => qw( slurp_fh tmpfile mimetype_is_text catfile );

=head1 NAME

SVK::Editor::Diff - An editor for producing textual diffs

=head1 SYNOPSIS

 $editor = SVK::Editor::Diff->new
    ( cb_basecontent => sub { ... },
      cb_baseprop    => sub { ... },
      cb_llabel      => sub { ... },
      # or llabel => 'revision <left>',
      cb_rlabel      => sub { ... },
      # or rlabel => 'revision <left>',
      oldtarget => $target, oldroot => $root,
    );
 $xd->depot_delta ( editor => $editor, ... );

=cut

sub set_target_revision {
    my ($self, $revision) = @_;
}

sub open_root {
    my ($self, $baserev) = @_;
    return '';
}

sub add_file {
    my ($self, $path, $pdir, $from_path, $from_rev, $pool) = @_;
    if (defined $from_path) {
	$self->_print
	    ( "=== $path\n",
	      loc ("== copy with modification can't be displayed, use svk patch --apply.\n" ));
	return;
    }
    $self->{info}{$path}{added} = 1;
    $self->{info}{$path}{fpool} = $pool;
    return $path;
}

sub open_file {
    my ($self, $path, $pdir, $rev, $pool) = @_;
    $self->{info}{$path}{fpool} = $pool;
    return $path;
}

sub apply_textdelta {
    my ($self, $path, $checksum, $pool) = @_;
    return unless $path;
    my $info = $self->{info}{$path};
    $info->{base} = $self->{cb_basecontent} ($path, $info->{fpool})
	unless $info->{added};

    unless ($self->{external}) {
	my $newtype = $info->{prop} && $info->{prop}{'svn:mime-type'};
	my $is_text = !$newtype || mimetype_is_text ($newtype);
	if ($is_text && !$info->{added}) {
	    my $basetype = $self->{cb_baseprop}->($path, 'svn:mime-type', $pool);
	    $is_text = !$basetype || mimetype_is_text ($basetype);
	}
	unless ($is_text) {
	    $self->_print (
                "=== $path\n",
                '=' x 66, "\n",
                loc("Cannot display: file marked as a binary type.\n")
            );
	    return undef;
	}
    }
    my $new;
    if ($self->{external}) {
	my $tmp = tmpfile ('diff');
	slurp_fh ($info->{base}, $tmp)
	    if $info->{base};
	seek $tmp, 0, 0;
	$info->{base} = $tmp;
	$info->{new} = $new = tmpfile ('diff');
    }
    else {
	$info->{new} = '';
	open $new, '>', \$info->{new};
    }

    return [SVN::TxDelta::apply ($info->{base}, $new,
				 undef, undef, $pool)];
}

sub close_file {
    my ($self, $path, $checksum, $pool) = @_;
    return unless $path;
    if (exists $self->{info}{$path}{new}) {
	no warnings 'uninitialized';
	my $rpath = $self->{report} ? catfile($self->{report}, $path) : $path;
	my $base = $self->{info}{$path}{added} ?
	    \'' : $self->{cb_basecontent} ($path, $self->{info}{$path}{fpool});
	my @label = map { $self->{$_} || $self->{"cb_$_"}->($path) } qw/llabel rlabel/;
	my $showpath = ($self->{lpath} ne $self->{rpath});
	my @showpath = map { $showpath ? $self->{$_} : undef } qw/lpath rpath/;
	if ($self->{external}) {
	    # XXX: the 2nd file could be - and save some disk IO
	    my @content = map { ($self->{info}{$path}{$_}->filename) } qw/base new/;
	    @content = reverse @content if $self->{reverse};
	    (system (split (/ /, $self->{external}),
		    '-L', _full_label ($rpath, $showpath[0], $label[0]),
		    $content[0],
		    '-L', _full_label ($rpath, $showpath[1], $label[1]),
		    $content[1]) >= 0) or die loc("Could not run %1: %2", $self->{external}, $?);
	}
	else {
	    my @content = ($base, \$self->{info}{$path}{new});
	    @content = reverse @content if $self->{reverse};
	    $self->output_diff ($rpath, @label, @showpath, @content);
	}
    }

    $self->output_prop_diff ($path, $pool);
    delete $self->{info}{$path};
}

sub _full_label {
    my ($path, $mypath, $label) = @_;

    my $full_label = "$path\t";
    if ($mypath) {
        $full_label .= "($mypath)\t";
    }
    $full_label .= "($label)";

    return $full_label;
}

sub output_diff {
    my ($self, $path, $llabel, $rlabel, $lpath, $rpath) = splice(@_, 0, 6);
    my $fh = $self->_output_fh;

    print $fh (
        "=== $path\n",
        '=' x 66, "\n",
    );

    unshift @_, $self->_output_fh;
    push @_, _full_label ($path, $lpath, $llabel),
             _full_label ($path, $rpath, $rlabel);

    goto &{$self->can('_output_diff_content')};
}

# _output_diff_content($fh, $ltext, $rtext, $llabel, $rlabel)
sub _output_diff_content {
    my $fh = shift;

    my ($lfh, $lfn) = tmpfile ('diff');
    my ($rfh, $rfn) = tmpfile ('diff');

    slurp_fh (shift(@_) => $lfh); close ($lfh);
    slurp_fh (shift(@_) => $rfh); close ($rfh);

    my $diff = SVN::Core::diff_file_diff( $lfn, $rfn );

    SVN::Core::diff_file_output_unified(
        $fh, $diff, $lfn, $rfn, @_,
    );

    unlink ($lfn, $rfn);
}

sub output_prop_diff {
    my ($self, $path, $pool) = @_;
    if ($self->{info}{$path}{prop}) {
	my $rpath = $self->{report} ? catfile($self->{report}, $path) : $path;
	$self->_print("\n", loc("Property changes on: %1\n", $rpath), ('_' x 67), "\n");
	for (sort keys %{$self->{info}{$path}{prop}}) {
	    $self->_print(loc("Name: %1\n", $_));
	    my $baseprop;
	    $baseprop = $self->{cb_baseprop}->($path, $_, $pool)
		unless $self->{info}{$path}{added};
            my @args =
                map \$_,
                map { (length || /\n$/) ? "$_\n" : $_ }
                    ($baseprop||''), ($self->{info}{$path}{prop}{$_}||'');
            @args = reverse @args if $self->{reverse};

            my $diff = '';
            open my $fh, '>', \$diff;
            _output_diff_content($fh, @args, '', '');
            $diff =~ s/.*\n.*\n//;
            $diff =~ s/^\@.*\n//mg;
            $diff =~ s/^/ /mg;
            $self->_print($diff);
	}
	$self->_print("\n");
    }
}

sub add_directory {
    my ($self, $path, $pdir, @arg) = @_;
    return $path;
}

sub open_directory {
    my ($self, $path, $pdir, $rev, @arg) = @_;
    return $path;
}

sub close_directory {
    my ($self, $path, $pool) = @_;
    $self->output_prop_diff ($path, $pool);
    delete $self->{info}{$path};
}

sub delete_entry {
    my ($self, $path, $revision, $pdir, $pool) = @_;
    my $spool = SVN::Pool->new_default;
    # generate delta between empty root and oldroot of $path, then reverse in output
    SVK::XD->depot_delta
	( oldroot => $self->{oldtarget}{repos}->fs->revision_root (0),
	  oldpath => [$self->{oldtarget}{path}, $path],
	  newroot => $self->{oldroot},
	  newpath => $self->{oldtarget}{path} eq '/' ? "/$path" : "$self->{oldtarget}{path}/$path",
	  editor => __PACKAGE__->new (%$self, reverse => 1),
	);

}

sub change_file_prop {
    my ($self, $path, $name, $value) = @_;
    $self->{info}{$path}{prop}{$name} = $value;
}

sub change_dir_prop {
    my ($self, $path, $name, $value) = @_;
    $self->{info}{$path}{prop}{$name} = $value;
}

sub close_edit {
    my ($self, @arg) = @_;
}

sub _print {
    my $self = shift;
    $self->{output} or return print @_;
    ${ $self->{output} } .= $_ for @_;
}

sub _output_fh {
    my $self = shift;

    no strict 'refs';
    $self->{output} or return \*{select()};

    open my $fh, '>>', $self->{output};
    return $fh;
}

=head1 AUTHORS

Chia-liang Kao E<lt>clkao@clkao.orgE<gt>

=head1 COPYRIGHT

Copyright 2003-2005 by Chia-liang Kao E<lt>clkao@clkao.orgE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut

1;
