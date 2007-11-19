package Sendmail::Queue::Df;
use strict;
use warnings;
use Carp;

use File::Spec;
use IO::File;
use Fcntl qw( :flock );

use Scalar::Util qw( blessed );

use base qw(Class::Accessor::Fast);
__PACKAGE__->follow_best_practice;
__PACKAGE__->mk_accessors( qw(
	queue_id
	queue_directory
	data
	hardlinked
) );

=head1 NAME

Sendmail::Queue::Df - Represent a Sendmail dfXXXXXX (data) file

=head1 SYNOPSIS

    use Sendmail::Queue::Df

    # Create a new df file object
    my $df = Sendmail::Queue::Df->new();

    # Give it an ID
    $df->set_queue_id( $some_qf->get_queue_id );

    # Give it some data directly
    $df->set_data( $scalar_with_body );

    # ... or, give some data from a filehandle
    $df->set_data_from( $some_fh );

    # ... or, hardlink it to another object, or to a pathname
    $df->hardlink_to( $other_df );
    $df->hardlink_to( '/path/to/file' );

    # Make sure it's on disk.
    $df->write( '/path/to/queue');

=head1 DESCRIPTION

Sendmail::Queue::Df provides a representation of a Sendmail df (data) file.

=head1 METHODS

=head2 new ( \%args )

Create a new Sendmail::Queue::Df object.

=cut

sub new
{
	my ($class, $args) = @_;

	my $self = {
		queue_directory => undef,
		queue_id => undef,
		data => undef,
		hardlinked => 0,
	};

	bless $self, $class;

	return $self;
}

=head2 hardlink_to ( $target )

Instead of writing a new data file, hardlink this one to an existing file.

$target can be either a L<Sendmail::Queue::Df> object, or a scalar pathname.

=cut

sub hardlink_to
{
	my ($self, $target) = @_;

	my $target_path = $target;

	if( ref $target && blessed $target eq 'Sendmail::Queue::Df' ) {
		$target_path = $target->get_data_filename();
	}

	if( ! -f $target_path ) {
		die qq{Path $target_path does not exist};
	}

	if( ! $self->get_data_filename ) {
		die qq{Current object has no path to hardlink!}
	}

	if( ! link $target_path, $self->get_data_filename ) {
		die qq{Hard link failed: $!};
	}

	$self->{hardlinked} = 1;

	return 1;
}

=head2 get_data_filename

Return the full path name of this data file.

Will die if queue directory is unset.

=cut

sub get_data_filename
{
	my ($self) = @_;

	if( ! $self->get_queue_directory ) {
		die q{queue directory not set};
	}

	return File::Spec->catfile( $self->get_queue_directory(), 'df' . $self->get_queue_id() );
}

=head2 set_data_from ( $data_fh )

Given a filehandle, read the data from it, up to the end of file, and
store it in the object.

=cut

sub set_data_from
{
	my ($self, $data_fh) = @_;

	$self->set_data( do { local $/; <$data_fh> } );
}

=head2 write ( ) 

Write data to df file, if necessary.

=cut

sub write
{
	my ($self) = @_;

	if ( $self->{hardlinked} ) {
		return 0;
	}

	if ( ! $self->get_queue_directory ) {
		die q{write() requires a queue directory};
	}

	if( ! $self->get_queue_id() ) {
		$self->generate_queue_id();
	}

	my $filepath = $self->get_data_filename();

	if( -e $filepath ) {
		die qq{File $filepath already exists; write() doesn't know how to overwrite yet};
	}

	my $fh = IO::File->new( $filepath, O_WRONLY|O_CREAT );
	if( ! $fh ) {
		die qq{File $filepath could not be created: $!};
	}

	if( ! flock $fh, LOCK_EX | LOCK_NB ) {
		die qq{Couldn't lock $filepath: $!};
	}

	if( ! $fh->print( $self->get_data ) ) {
		die qq{Couldn't print to $filepath: $!};
	}

	if( ! $fh->flush ) {
		die qq{Couldn't flush $filepath: $!};
	}

	if( ! $fh->sync ) {
		die qq{Couldn't sync $filepath: $!};
	}

	if( ! $fh->close ) {
		die qq{Couldn't close $filepath: $!};
	}

	return 1;
}


1;
__END__


=head1 DEPENDENCIES

=head2 Core Perl Modules

L<Carp>, L<Scalar::Util>

=head2 Other Modules

=head1 INCOMPATIBILITIES

There are no known incompatibilities with this module.

=head1 BUGS AND LIMITATIONS

There are no known bugs in this module.
Please report problems to the author.
Patches are welcome.

=head1 AUTHOR

David F. Skoll, C<< <support at roaringpenguin.com> >>
Dave O'Neill, C<< <support at roaringpenguin.com> >>

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2007 Roaring Penguin Software, Inc.  All rights reserved.
