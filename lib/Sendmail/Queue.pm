package Sendmail::Queue;
use strict;
use warnings;
use Carp;

our $VERSION = 0.01;

use Sendmail::Queue::Qf;
use Sendmail::Queue::Df;
use File::Spec;
use IO::Handle;
use Fcntl;

=head1 NAME

Sendmail::Queue - Manipulate Sendmail queues directly

=head1 SYNOPSIS

    use Sendmail::Queue;

    # The high-level interface:
    #
    # Create a new queue object.  Throws exception on error.
    my $q = Sendmail::Queue->new({
        queue_directory => '/var/spool/mqueue'
    });

    # Queue one copy of a message (one qf, one df)
    my $id = $q->queue_message({
	sender     => 'user@example.com',
	recipients => [
		'first@example.net',
		'second@example.org',
	]
	data       => $string_or_object,
    });

    # Queue multiple copies of a message using multiple envelopes, but
    # the same body.  Results contain the recipient set name as key,
    # and the queue ID as the value.
    my %results = $q->queue_multiple({
	sender         => 'user@example.com',
	recipient_sets => {
		'set one' => [
			'first@example.net',
			'second@example.org',
		],
		'set two' => [
		],
	},
	data           => $string_or_object,
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

=item queue_directory

The queue directory to use.  Should (usually) be the same as your
Sendmail QueueDirectory variable for the client submission queue.

=back

=cut

sub new
{
	my ($class, $args) = @_;

	$args ||= {};

	if( ! exists $args->{queue_directory} ) {
		die q{queue_directory argument must be provided};
	}

	my $self = {
		queue_directory => $args->{queue_directory},
	};


	bless $self, $class;

	if( ! -d $self->{queue_directory} ) {
		die q{ Queue directory doesn't exist};
	}

	if( -d File::Spec->catfile($self->{queue_directory},'qf')
 	    && -d File::Spec->catfile($self->{queue_directory},'df') ) {
		$self->{_qf_directory} = File::Spec->catfile($self->{queue_directory},'qf');
		$self->{_df_directory} = File::Spec->catfile($self->{queue_directory},'df');
	} else {
		$self->{_qf_directory} = $self->{queue_directory};
		$self->{_df_directory} = $self->{queue_directory};
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

Optional arguments may be specified as well.  These will be handed off
directly to the underlying Sendmail::Queue::Qf object:

=over 4

=item product_name

Name to use for this product in the generated Recieved: header.  May be
set to blank or undef to disable.  Defaults to 'Sendmail::Queue'.

=item helo

The HELO or EHLO name provided by the host that sent us this message,
or undef if none.  Defaults to undef.

=item relay_address

The IP address of the host that sent us this message, or undef if none.
Defaults to undef.

=item relay_hostname

The name of the host that sent us this message, or undef if none.
Defaults to undef.

=item local_hostname

The name of the host that received this message.  Defaults to 'localhost'

=item protocol

Protocol over which this message was received.  Valid values are blank,
SMTP, and ESMTP.  Default is blank.

=item timestamp

A UNIX seconds-since-epoch timestamp.  If omitted, defaults to current time.

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

	# Allow passing of optional info down to Qf object
	foreach my $optarg qw( product_name helo relay_address relay_hostname local_hostname protocol timestamp ) {
		if( exists $args->{$optarg} ) {
			$qf->set( $optarg, $args->{$optarg} );
		}
	}


	$qf->create_and_lock();
	$qf->set_sender( $args->{sender} );
	$qf->add_recipient( @{ $args->{recipients} } );

	$qf->set_headers( $headers );

	# Generate a Received header
	$qf->synthesize_received_header();

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


=head2 queue_multiple ( $args )

Queue multiple copies of a message using multiple envelopes, but the
same body.

Returns a results hash containing the recipient set name as key, and the
queue ID as the value.


    my %results = $q->queue_multiple({
	sender         => 'user@example.com',
	recipient_sets => {
		'set one' => [
			'first@example.net',
			'second@example.org',
		],
		'set two' => [
		],
	},
	data           => $string_or_object,
    });

=cut

sub queue_multiple
{
	my ($self, $args) = @_;

	foreach my $argname qw( sender recipient_sets data ) {
		die qq{$argname argument must be specified} unless exists $args->{$argname}

	}

	if( ref $args->{data} ) {
		die q{data as an object not yet supported};
	}

	my ($headers, $body) = split(/\n\n/, $args->{data}, 2);

	my $qf = Sendmail::Queue::Qf->new();
	$qf->set_queue_directory($self->{_qf_directory});

	# Allow passing of optional info down to Qf object
	foreach my $optarg qw( product_name helo relay_address relay_hostname local_hostname protocol timestamp ) {
		if( exists $args->{$optarg} ) {
			$qf->set( $optarg, $args->{$optarg} );
		}
	}

	# Prepare a generic queue file
	$qf->set_sender( $args->{sender} );
	$qf->set_headers( $headers );

	my ($first_qf, $first_df);

	my %results;

	# Now, loop over all of the rest
	foreach my $set_key ( keys %{ $args->{recipient_sets} }) {
		my $cur_qf = $qf->clone();
		$cur_qf->add_recipient( @{ $args->{recipient_sets}{$set_key} } );
		$cur_qf->create_and_lock();
		$cur_qf->synthesize_received_header();
		$cur_qf->write();
		$cur_qf->sync();

		my $cur_df = Sendmail::Queue::Df->new();
		$cur_df->set_queue_directory($self->{_df_directory});
		$cur_df->set_queue_id( $cur_qf->get_queue_id );
		if( ! $first_qf ) {
			# If this is the first one, create and write
			# the df file, and leave the qf open and
			# locked.
			$first_qf = $cur_qf;
			$first_df = $cur_df;
			$first_df->set_data( $body );
			$first_df->write();
		} else {
			# Otherwise
			$cur_df->hardlink_to( $first_df->get_data_filename() );
			$cur_qf->close();
		}

		$results{ $set_key } = $cur_qf->get_queue_id;
	}

	# Close the first queue file to release the lock
	$first_qf->close();

	$self->sync();

	return \%results;
}

=head2 sync ( )

Ensure that the queue directories have been synced.

=cut

sub sync
{
	my ($self) = @_;

	# Evil hack.  Why?  Well:
	#   - you can't fsync() a filehandle directly, you must use
	#     IO::Handle->sync
	# so, we have to sysopen to a filehandle glob, and then fdopen
	# the fileno we get from that glob.

	my $directory = $self->{_df_directory};

	sysopen(DIR_FH, $directory, O_RDONLY) or die qq{Couldn't sysopen $directory: $!};

	my $handle = IO::Handle->new();
	$handle->fdopen(fileno(DIR_FH), "w") or die qq{Couldn't fdopen the directory handle: $!};
	$handle->sync or die qq{Couldn't sync: $!};

	close(DIR_FH);

	return 1;
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
