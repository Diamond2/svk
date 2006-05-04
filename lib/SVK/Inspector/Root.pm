package SVK::Inspector::Root;

use strict;
use warnings;


use base qw {
	SVK::Inspector
};

__PACKAGE__->mk_accessors(qw{root anchor});


sub exist {
    my ($self, $path, $pool) = @_;
    $path = $self->_anchor_path($path);
    return $self->root->check_path ($path, $pool);
}

sub localmod {
    my ($self, $path, $checksum, $pool) = @_;
    $path = $self->_anchor_path($path);
    my $md5 = $self->root->file_md5_checksum ($path, $pool);
    return if $md5 eq $checksum;
    return [$self->root->file_contents ($path, $pool), undef, $md5];
}

sub localprop {
    my ($self, $path, $propname, $pool) = @_;
    my $oldpath = $path;
    $path = $self->_anchor_path($path);
    local $@;
    return eval { $self->root->node_prop ($path, $propname, $pool) };
}

sub dirdelta { 
    my ($self, $path, $base_root, $base_path, $pool) = @_;
    my $modified = {};
    SVK::XD->depot_delta (oldroot => $base_root, newroot => $self->root,
             oldpath => [$base_path, ''],
             newpath => $self->_anchor_path($path),
             editor => $self->dirdelta_status_editor($modified),
             no_textdelta => 1, no_recurse => 1);
    return $modified;
}

sub _anchor_path {
    my ($self, $path) = @_;
    $path = $self->translate($path);
    return $path if $path =~ m{^/};
    return $self->anchor unless length $path;
    return $self->anchor."/$path";
}

1;
