package Sendmail::Queue;
use strict;
use warnings;
use Carp;

our $VERSION = 0.01;

use Sendmail::Queue::Qf;
use Sendmail::Queue::Df;

=head1 NAME

Sendmail::Queue - Manipulate Sendmail queues directly

=head1 SYNOPSIS

    use Sendmail::Queue;

    # The high-level interface:
    #
    # Create a new queue object.  Throws exception on error.
    my $q = Sendmail::Queue->new({
        QueueDirectory => '/var/spool/mqueue'
    });

    my $id = $q->queue_message({
	sender     => 'user@example.com',
	recipients => [
		'first@example.net',
		'second@example.org',
	]
	data      => $string_or_object,
    });

    # The low-level interface:

    # Create a new qf file object
    my $qf = Sendmail::Queue::Qf->new();

    # Generate a Sendmail 8.12-compatible queue ID
    $qf->create_and_lock();

    my $df = Sendmail::Queue::Df->new();

    # Need to give it the same queue ID as your $qf
    $df->set_queue_id( $qf->get_queue_id );
    $df->set_data( $some_body );

    # Or....
    $df->set_data_from( $some_fh );

    # Or, if you already have a file...
    my $second_df = Sendmail::Queue::Df->new();
    $second_df->set_queue_id( $qf->get_queue_id );
    $second_df->hardlink_to( $df ); # Need better name

    $qf->set_defaults();
    $qf->set_sender('me@example.com');
    $qf->add_recipient('you@example.org');

    $q->enqueue( $qf, $df );

=head1 DESCRIPTION

Sendmail::Queue provides a mechanism for directly manipulating Sendmail queue files.

=head1 METHODS

=head2 new ( \%args )

Create a new Sendmail::Queue object.

Required arguments are:

=over 4

=item QueueDirectory

The queue directory to use.

=back

=cut

sub new
{
	my ($class, $args) = @_;

	$args ||= {};

	if( ! exists $args->{QueueDirectory} ) {
		die q{QueueDirectory argument must be provided};
	}

	my $self = {
		QueueDirectory => $args->{QueueDirectory},
	};


	bless $self, $class;

	if( ! -d $self->{QueueDirectory} ) {
		die q{ Queue directory doesn't exist};
	}

	if( -d "$self->{QueueDirectory}/qf" ) {  # TODO:: Use File::Path
		# We have separate /qf, /df, /xf, maybe
		# TODO:
		# 	- verify that all three exist
		# 	- update _qf_directory and _df_directory
		# 	appropriately
	} else {
		$self->{_qf_directory} = $self->{QueueDirectory};
		$self->{_df_directory} = $self->{QueueDirectory};
	}

	return $self;
}

=head2 queue_message ( $args )

High-level interface for queueing a message.  Creates qf and df files
in the object's queue directory using the arguments provided.

Returns the queue ID for the queued message.

Required arguments:

=over 4

=item sender

Envelope sender for message.

=item recipients

Array ref containing one or more recipients for this message.

=item data

Scalar containing message headers and body, in mbox format (separated by \n\n).

=back

On error, this method may die() with a number of different runtime errors.

=cut

sub queue_message
{
	my ($self, $args) = @_;

	foreach my $argname qw( sender recipients data ) {
		die qq{$argname argument must be specified} unless exists $args->{$argname}

	}

	if( ref $args->{data} ) {
		die q{data as an object not yet supported};
	}

	my ($headers, $body) = split(/\n\n/, $args->{data}, 2);

	my $qf = Sendmail::Queue::Qf->new();
	$qf->set_queue_directory($self->{_qf_directory});

	$qf->create_and_lock();
	$qf->set_sender( $args->{sender} );
	$qf->add_recipient( @{ $args->{recipients} } );
	$qf->set_headers( $headers );

	my $df = Sendmail::Queue::Df->new();
	$df->set_queue_directory($self->{_df_directory});
	$df->set_queue_id( $qf->get_queue_id );
	$df->set_data( $body );

	$self->enqueue( $qf, $df);

	return $qf->get_queue_id;
}

# Returns success, or dies.
sub enqueue
{
	my ($self, $qf, $df) = @_;

	eval {
		$df->write();
		$qf->write();
		$qf->sync();
		$qf->close();

		chmod( 0664, $df->get_data_filename, $qf->get_queue_filename) or die qq{chmod fail: $!};
	};
	if( $@ ) { ## no critic
#		$df->delete();
#		$qf->delete();

		# Rethrow the exception after cleanup
		die $@;
	}

	return 1;
}

sub sync
{
	# TODO: open the _df_directory/_qf_directory explicitly and
	# fsync it so that the directory entries are synced.
	# We do this because file writes can be sync'ed when closed,
	# but any hardlinks won't be unless we sync the dir
}

1;
__END__


=head1 DEPENDENCIES

=head2 Core Perl Modules

L<Carp>

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
