package Sendmail::Queue::Df;
use strict;
use warnings;
use Carp;

use Scalar::Util qw( blessed );

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

	# TODO: need get/set methods for these
	my $self = { 
		queue_directory => undef,
		queue_id => undef,
		data => undef,
		is_hardlinked => 0,
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

	if( blessed $target eq 'Sendmail::Queue::Df' ) {
		$target_path = $target->get_path();
	}

	if( ! -f $target_path ) {
		die qq{Path $target_path does not exist};
	}

	if( ! $self->get_path ) {
		die qq{Current object has no path to hardlink!}
	}

	if( ! link $target_path, $self->get_path ) {
		die qq{Hard link failed: $!};
	}

	$self->{is_hardlinked} = 1;

	return 1;
}

=head2 write ( ) 

Write data to df file, if necessary.

=cut

sub write
{
	my ($self) = @_;

	if ( $self->{is_hardlinked} ) {
		return 0;
	}

	# TODO: write data to df file
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
