package SVN::XD;
use strict;
require SVN::Core;
require SVN::Repos;
require SVN::Fs;
require SVN::Delta;
use Data::Hierarchy;
use File::Spec;
use YAML;
use Algorithm::Merge; # Text::Merge instead

our $VERSION = '0.01';

sub new {
    my $class = shift;
    my $self = bless {}, $class;
    %$self = @_;
    return $self;
}

sub create_xd_root {
    my ($info, %arg) = @_;
    my $fs = $arg{repos}->fs;
    my ($txn, $root);

    my @paths = $info->{checkout}->find ($arg{copath}, {revision => qr'.*'});

    return (undef,
	    $fs->revision_root ($info->{checkout}->get ($paths[0])->{revision}))
	unless $#paths;

    for (@paths) {
	my $rev = $info->{checkout}->get ($_)->{revision};
	if ($_ eq $arg{copath}) {
	    $txn = $fs->begin_txn ($rev);
	    $root = $txn->root();
	    next;
	}
	s|^$arg{copath}/||;
	SVN::Fs::revision_link ($fs->revision_root ($rev),
				$root, "$arg{path}/$_");
    }
    return ($txn, $root);
}

sub do_update {
    my ($info, %arg) = @_;
    my $fs = $arg{repos}->fs;
    my $xdroot;
    my $txn;

    print "syncing $arg{depotpath}($arg{path}) to $arg{copath} to $arg{rev}\n";
    my (undef,$anchor,$target) = File::Spec->splitpath ($arg{path});
    my (undef,undef,$copath) = File::Spec->splitpath ($arg{copath});
    if ($anchor eq '/') {
	$anchor = '';
	$target = '/';
    }
    chop $anchor if length($anchor) > 1;

#    warn "$anchor $target ($arg{path} -> $arg{copath})";
#    $target ||= '/';
    ($txn, $xdroot) = create_xd_root ($info, %arg);

    SVN::Repos::dir_delta ($xdroot, $anchor, $target,
			   $fs->revision_root ($arg{rev}), $arg{path},
			   SVN::XD::UpdateEditor->new (_debug => 0,
						       target => $target eq '/' ? '' : $target,
						       copath => $arg{copath},
						      ),
#			   SVN::Delta::Editor->new(_debug=>1),
			   1, 1, 0, 1);

    SVN::Fs::close_txn ($txn) if $txn;

    $info->{checkout}->store_recursively ($arg{copath},
					  {revision => $arg{rev}});
}

sub do_add {
    my ($info, %arg) = @_;

    find(sub {
	     my $cpath = $File::Find::name;
	     # do dectation also
	     $info->{checkout}->store ($cpath, { schedule => 'add' });
	     print "A  $cpath\n";
	 }, $arg{copath});

    $info->{checkout}->store ($arg{copath}, { schedule => 'add' });

}

sub do_delete {
    my ($info, %arg) = @_;

    # check for if the file/dir is modified.

    # actually remove it from checkout path
    die "not yet";
}

use File::Find;

sub checkout_crawler {
    my ($info, %arg) = @_;

    my %schedule = map {$_ => $info->{checkout}->get ($_)->{schedule}}
	$info->{checkout}->find ($arg{copath}, {schedule => qr'.*'});

    my ($txn, $xdroot) = create_xd_root ($info, %arg);

    find(sub {
	     my $cpath = $File::Find::name;

	     $cpath =~ s|^$arg{copath}/|$arg{path}/|;
	     $cpath = '' if $cpath eq $arg{copath};
	     if (exists $schedule{$File::Find::name}) {
		 &{$arg{cb_add}} ($cpath, $File::Find::name)
		     if $arg{cb_add};
		 return;
	     }
	     my $kind = $xdroot->check_path ($cpath);
	     if ($kind == $SVN::Node::none) {
		 &{$arg{cb_unknown}} ($cpath, $File::Find::name)
		     if $arg{cb_unknown};
		 return;
	     }
	     return if -d $File::Find::name;
	     &{$arg{cb_changed}} ($cpath, $File::Find::name)
		 if $arg{cb_changed} && md5file($File::Find::name) ne
		     $xdroot->file_md5_checksum ($cpath);
	  }, $arg{copath});
    SVN::Fs::close_txn ($txn) if $txn;
}

use SVN::Simple::Edit;

sub do_commit {
    my ($info, %arg) = @_;

    my $committed = sub {
	my ($rev) = @_;
	for (@{$arg{targets}}) {
	    $info->{checkout}->store ($_->[1], { schedule => undef,
						 revision => $rev,
					       });
	}
	print "Committed revision $rev.\n";
    };

    print "commit message from $arg{author}:\n$arg{message}\n";
    my (undef,$anchor,$target) = File::Spec->splitpath ($arg{path});
    my (undef,undef,$copath) = File::Spec->splitpath ($arg{copath});

    print "commit from $arg{path} ($anchor & $target) <- $arg{copath}\n";
    print "targets:\n";
    print "$_->[1]\n" for @{$arg{targets}};

    my $fs = $arg{repos}->fs;

    my $edit = SVN::Simple::Edit->new
	(_editor => [SVN::Repos::get_commit_editor($arg{repos},
						   "file://$arg{repospath}",
						   $arg{path},
						   $arg{author}, $arg{message},
						   $committed)],
	 missing_handler =>
	 SVN::Simple::Edit::check_missing ($fs->revision_root ($arg{baserev})));

    $edit->open_root($arg{baserev});
    for (@{$arg{targets}}) {
	my ($action, $tpath) = @$_;
	my $cpath = $tpath;
#	($tpath eq $arg{copath}) ? '$tpath';
	$tpath =~ s|^$arg{copath}/|| or die "absurb path";
	if (-d $cpath) {
	    $edit->add_directory ($tpath);
	    next;
	}
	open my ($fh), '<', $cpath;
	my $md5 = md5file ($cpath);
	if ($action eq 'A') {
	    # check dir later
	    $edit->add_file ($tpath);
	}
	$edit->modify_file ($tpath, $fh, $md5);
    }
    $edit->close_edit();

}

sub md5file {
    my $fname = shift;
    open my $fh, '<', $fname;
    my $ctx = Digest::MD5->new;
    $ctx->addfile($fh);
    return $ctx->hexdigest;
}


package SVN::XD::UpdateEditor;
require SVN::Delta;
our @ISA = qw(SVN::Delta::Editor);
use File::Path;
use Digest::MD5;

sub md5 {
    my $fh = shift;
    my $ctx = Digest::MD5->new;
    $ctx->addfile($fh);
    return $ctx->hexdigest;
}

sub open_root {
    my ($self, $baserev) = @_;
    $self->{baserev} = $baserev;
    return '';
}

sub add_file {
    my ($self, $path) = @_;
    $path =~ s|^$self->{target}/|$self->{copath}/|;
    $self->{info}{$path}{status} = (-e $path ? undef : ['A']);
    return $path;
}

sub open_file {
    my ($self, $path) = @_;
    $path =~ s|^$self->{target}/|$self->{copath}/|;
    $self->{info}{$path}{status} = (-e $path ? [] : undef);
    return $path;
}

sub apply_textdelta {
    my ($self, $path, $checksum) = @_;
    return unless $self->{info}{$path}{status};
    my ($fh, $base);
    unless ($self->{info}{$path}{status}[0]) {
	my (undef,$dir,$file) = File::Spec->splitpath ($path);
	open $base, '<', $path;

	if ($checksum) {
	    my $md5 = md5($base);
	    if ($checksum ne $md5) {
		warn "base checksum mismatch for $path, should do merge";
		warn "$checksum vs $md5($path)\n";
		close $base;
		undef $self->{info}{$path}{status};
		return undef;
#		$self->{info}{$path}{status}[0] = 'G';
	    }
	    seek $base, 0, 0;
	}
	$self->{info}{$path}{status}[0] = 'U';

	my $basename = "$dir.svk.$file.base";
	rename ($path, $basename);
	$self->{info}{$path}{base} = [$base, $basename];

    }
    open $fh, '>', $path or warn "can't open $path";
    $self->{info}{$path}{fh} = $fh;
    return [SVN::TxDelta::apply ($base || SVN::Core::stream_empty(),
				 $fh, undef, undef)];
}

sub close_file {
    my ($self, $path, $checksum) = @_;
    my $info = $self->{info}{$path};
    no warnings 'uninitialized';
    # let close_directory reports about its children
    if ($info->{status}) {
	print sprintf ("%1s%1s \%s\n",$info->{status}[0],
		       $info->{status}[1], $path);
    }
    else {
	print "   $path - skipped\n";
    }
    if ($info->{base}) {
	close $info->{base}[0];
	unlink $info->{base}[1];
    }
    close $info->{fh};
    undef $self->{info}{$path};
}

sub add_directory {
    my ($self, $path) = @_;
    $path = $self->{copath} if $path eq $self->{copath};
    $path =~ s|^$self->{target}/|$self->{copath}/|;
    mkdir ($path);
    return $path;
}

sub open_directory {
    my ($self, $path) = @_;
    $path = $self->{copath} if $path eq $self->{copath};
    $path =~ s|^$self->{target}/|$self->{copath}/|;
    return $path;
}

sub close_directory {
    my ($self, $path) = @_;
    print ".  $path\n";
}


sub delete_entry {
    my ($self, $path, $revision) = @_;
    $path =~ s|^$self->{target}/|$self->{copath}/|;
    # check if everyone under $path is sane for delete";
    -d $path ? rmtree ([$path]) : unlink($path);
    $self->{info}{$path}{status} = ['D'];
}

sub close_edit {
    my ($self) = @_;
    print "finishing update\n";
}


1;
