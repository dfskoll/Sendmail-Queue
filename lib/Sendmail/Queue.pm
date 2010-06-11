package Sendmail::Queue;
use strict;
use warnings;
use Carp;
use 5.8.0;

our $VERSION = '0.100';

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
	],
	data       => $string_or_object,
    });

    # Queue multiple copies of a message using multiple envelopes, but
    # the same body.  Results contain the recipient set name as key,
    # and the queue ID as the value.
    my %results = $q->queue_multiple({
	sender         => 'user@example.com',
	envelopes => {
		'envelope one' => {
			sender     => 'differentuser@example.com',
			recipients => [
				'first@example.net',
				'second@example.org',
			],
		},
		'envelope two' => {
			recipients => [
				'third@example.net',
				'fourth@example.org',
			],
		}
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

Scalar containing message headers and body, in RFC-2822 format (ASCII
text, headers separated from body by \n\n).

Data should use local line-ending conventions (as used by Sendmail) and
not the \r\n used on the wire for SMTP.

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

TODO: document the possible errors
TODO: use exceptions??

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

	$args->{envelopes} = {
		single_envelope => {
			recipients => delete $args->{recipients}
		}
	};

	my $result = $self->queue_multiple( $args );

	return $result->{single_envelope};
}

=head2 enqueue ( $qf, $df )

Enqueue a message, given a L<Sendmail::Queue::Qf> object and a
L<Sendmail::Queue::Df> object.

This method is mostly for internal use.  You should probably use
C<queue_message()> or C<queue_multiple()> instead.

Returns true if queuing was successful.  Otherwise, cleans up any qf
and df data that may have been written to disk, and rethrows any
exception that may have occurred.

=cut

=for internal doc

Here are the file ops (from inotify) on a /usr/sbin/sendmail enqueuing:

/var/spool/mqueue-client/ CREATE dfo2JEQb7J002161
/var/spool/mqueue-client/ OPEN dfo2JEQb7J002161
/var/spool/mqueue-client/ MODIFY dfo2JEQb7J002161
/var/spool/mqueue-client/ CLOSE_WRITE,CLOSE dfo2JEQb7J002161
/var/spool/mqueue-client/ OPEN dfo2JEQb7J002161
/var/spool/mqueue-client/ CREATE qfo2JEQb7J002161
/var/spool/mqueue-client/ OPEN qfo2JEQb7J002161
/var/spool/mqueue-client/ MODIFY qfo2JEQb7J002161
/var/spool/mqueue-client/ CREATE tfo2JEQb7J002161
/var/spool/mqueue-client/ OPEN tfo2JEQb7J002161
/var/spool/mqueue-client/ MODIFY tfo2JEQb7J002161
/var/spool/mqueue-client/ MOVED_FROM tfo2JEQb7J002161
/var/spool/mqueue-client/ MOVED_TO qfo2JEQb7J002161
/var/spool/mqueue-client/ OPEN,ISDIR 
/var/spool/mqueue-client/ CLOSE_NOWRITE,CLOSE,ISDIR 
/var/spool/mqueue-client/ CLOSE_WRITE,CLOSE qfo2JEQb7J002161
/var/spool/mqueue-client/ CLOSE_NOWRITE,CLOSE dfo2JEQb7J002161


=cut

sub enqueue
{
	my ($self, $qf, $df) = @_;

	eval {
		$df->write();
		$qf->write();
		$qf->sync();
		$qf->close();
	};
	if( $@ ) { ## no critic
		$df->unlink();
		$qf->unlink();

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
	envelopes => {
		'envelope one' => {
			sender     => 'user@example.com',
			recipients => [
				'first@example.net',
				'second@example.org',
			],
		}
		'envelope two' => {
			sender     => 'user@example.com',
			recipients => [
				'third@example.net',
				'fourth@example.org',
			],
		}
	},
	data           => $string_or_object,
    });

=cut

sub queue_multiple
{
	my ($self, $args) = @_;

	foreach my $argname qw( envelopes data ) {
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
	$qf->set_headers( $headers );

	my $first_df;
	my @locked_qfs = ();

	my %results;

	# Now, loop over all of the rest
	# TODO: catch errors and delete partially-queued messages
	# TODO: what if one envelope set errors out?  Do we bail on all?  Probably.
	# TODO: validate data in the envelopes sections?
	while( my($env_name, $env_data) = each %{ $args->{envelopes} } ) {
		my $cur_qf = $qf->clone();

		my $sender = exists $env_data->{sender}
				? $env_data->{sender}
				: exists $args->{sender}
					? $args->{sender}
					: die q{no 'sender' available};

		$cur_qf->set_sender( $sender );
		$cur_qf->add_recipient( @{ $env_data->{recipients} } );
		$cur_qf->create_and_lock();
		$cur_qf->synthesize_received_header();
		$cur_qf->write();
		$cur_qf->sync();

		my $cur_df = Sendmail::Queue::Df->new();
		$cur_df->set_queue_directory($self->{_df_directory});
		$cur_df->set_queue_id( $cur_qf->get_queue_id );
		if( ! $first_df ) {
			# If this is the first one, create and write
			# the df file
			$first_df = $cur_df;
			$first_df->set_data( $body );
			$first_df->write();
		} else {
			# Otherwise, link to the first df
			$cur_df->hardlink_to( $first_df->get_data_filename() );
		}
		push @locked_qfs, $cur_qf;

		$results{ $env_name } = $cur_qf->get_queue_id;
	}

	# Close the queue files to release the locks
	$_->close() for (@locked_qfs);

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
	# TODO: this needs testing on solaris and bsd
	# TODO: this needs testing on other versions of Perl (5.10?)
	my $directory = $self->{_df_directory};

	sysopen(DIR_FH, $directory, O_RDONLY) or die qq{Couldn't sysopen $directory: $!};

	my $handle = IO::Handle->new();
	$handle->fdopen(fileno(DIR_FH), 'w') or die qq{Couldn't fdopen the directory handle: $!};
	$handle->sync or die qq{Couldn't sync: $!};
	$handle->close;

	close(DIR_FH);

	return 1;
}

1;
__END__


=head1 DEPENDENCIES

=head2 Core Perl Modules

L<Carp>

# TODO list other core perl modules

=head2 Other Modules

# TODO we shouldn't have non-core dependencies!  Check!

=head1 INCOMPATIBILITIES

There are no known incompatibilities with this module.

=head1 BUGS AND LIMITATIONS

There are no known bugs in this module.  However, it messes with
undocumented bits of Sendmail.  YMMV.

Please report problems to the author.
Patches are welcome.

=head1 AUTHOR

Dave O'Neill, C<< <support at roaringpenguin.com> >>

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2007 Roaring Penguin Software, Inc.  All rights reserved.
