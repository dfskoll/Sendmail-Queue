package Sendmail::Queue::Qf;
use strict;
use warnings;
use Carp;

use Scalar::Util qw(blessed);
use File::Spec;
use IO::File;
use Time::Local ();
use Fcntl qw( :flock );

use base qw(Class::Accessor::Fast);
__PACKAGE__->follow_best_practice;
__PACKAGE__->mk_accessors( qw(
	queue_id
	queue_fh
	queue_directory
	sender
	recipients
	headers
	timestamp
	product_name
	helo
	relay_address
	relay_hostname
	local_hostname
	protocol
	received_header
	priority
) );

=head1 NAME

Sendmail::Queue::Qf - Represent a Sendmail qfXXXXXXXX (control) file

=head1 SYNOPSIS

    use Sendmail::Queue::Qf;

    # Create a new qf file object
    my $qf = Sendmail::Queue::Qf->new({
	queue_directory => $dir
    });

    # Creates a new qf file, locked.
    $qf->create_and_lock();

    $qf->set_sender('me@example.com');
    $qf->add_recipient('you@example.org');

    $qf->set_headers( $some_header_data );

    # Add a received header using the information already provided
    $qf->synthesize_received_header();

    $qf->write( '/path/to/queue');

    $qf->sync();

    $qf->close();

=head1 DESCRIPTION

Sendmail::Queue::Qf provides a representation of a Sendmail qf file.

=head1 METHODS

=head2 new ( \%args )

Create a new Sendmail::Queue::Qf object.

=cut

sub new
{
	my ($class, $args) = @_;

	my $self = {
		queue_directory => $args->{queue_directory},
		queue_id => undef,
		sender => undef,
		headers => '',
		recipients => [],
		product_name => 'Sendmail::Queue',
		local_hostname => 'localhost',
		timestamp => time,
		priority => 30000,
	};

	bless $self, $class;

	return $self;
}

{
	my @base_60_chars = ( 0..9, 'A'..'Z', 'a'..'x' );
	sub _generate_queue_id_template
	{
		my ($time) = @_;
		$time = time unless defined $time;
		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime( $time );

		# First char is year minus 1900, mod 60
		# (perl's localtime conveniently gives us the year-1900 already)
		# 2nd and 3rd are month, day
		# 4th through 6th are hour, minute, second
		# 7th and 8th characters are a random sequence number
		# (to be filled in later)
		# 9th through 14th are the PID
		my $tmpl = join('', @base_60_chars[
			$year % 60,
			$mon,
			$mday,
			$hour,
			$min,
			$sec],
			'%2.2s',
			sprintf('%06d', $$)
		);

		return $tmpl;
	}

	sub _fill_template
	{
		my ($template, $seq_number) = @_;

		return sprintf $template,
			$base_60_chars[ int($seq_number / 60) ] . $base_60_chars[ $seq_number % 60 ];
	}
}

=head2 create_and_lock ( )

Generate a Sendmail 8.12-compatible queue ID, and create a locked qf
file with that name.

See Bat Book 3rd edition, section 11.2.1 for information on how the
queue file name is generated.

=cut

sub create_and_lock
{
	my ($self) = @_;

	if( ! -d $self->get_queue_directory ) {
		die qq{Cannot create queue file without queue directory!};
	}

	# 7th and 8th is random sequence number
	my $seq = int(rand(3600));

	my $tmpl = _generate_queue_id_template( $self->get_timestamp );

	my $iterations = 0;
	while( ++$iterations < 3600 ) {
		my $qid  = _fill_template($tmpl, $seq);
		my $path = File::Spec->catfile( $self->{queue_directory}, "qf$qid" );

		my $fh = IO::File->new( $path, O_RDWR|O_CREAT|O_EXCL );
		if( $fh ) {
			if( ! flock $fh, LOCK_EX | LOCK_NB ) {
				die qq{Couldn't lock $path: $!};
			}
			$self->set_queue_id( $qid );
			$self->set_queue_fh( $fh  );
			last;
		} elsif( $! == 17 ) {  # 17 == EEXIST
			# Try the next one
			carp "$path exists, incrementing sequence";
			$seq = ($seq + 1) % 3600;
		} else {
			die qq{Error creating qf file $path: $!};
		}

	}

	if ($iterations >= 3600 ) {
		die qq{Could not create queue file; too many iterations};
	}

	return 1;
}

# _tz_diff and _format_rfc2822_date borrowed from Email::Date.  Why?
# Because they depend on Date::Parse and Time::Piece, and I don't want
# to add them as dependencies.
# Similar functions exist in MIMEDefang as well
sub _tz_diff
{
	my ($time) = @_;

	my $diff  =   Time::Local::timegm(localtime $time)
	            - Time::Local::timegm(gmtime    $time);

	my $direc = $diff < 0 ? '-' : '+';
	$diff     = abs $diff;
	my $tz_hr = int( $diff / 3600 );
	my $tz_mi = int( $diff / 60 - $tz_hr * 60 );

	return ($direc, $tz_hr, $tz_mi);
}

sub _format_rfc2822_date
{
	my ($time) = @_;
	$time = time unless defined $time;

	my ($sec, $min, $hour, $mday, $mon, $year, $wday) = localtime $time;
	my $day   = (qw[Sun Mon Tue Wed Thu Fri Sat])[$wday];
	my $month = (qw[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec])[$mon];
	$year += 1900;

	my ($direc, $tz_hr, $tz_mi) = _tz_diff($time);

	sprintf "%s, %d %s %d %02d:%02d:%02d %s%02d%02d",
	    $day, $mday, $month, $year, $hour, $min, $sec, $direc, $tz_hr, $tz_mi;
}

=head2 synthesize_received_header ( )

Create a properly-formatted Received: header for this message, using
any data available from the object.

The generated header is saved internally as 'received_header'.

=cut

sub synthesize_received_header
{
	my ($self) = @_;

	my $header = 'Received: ';

	# Add relay address, if we have one
	if( $self->get_relay_address ) {
		$header .= 'from';
		if( $self->get_helo ) {
			$header .= ' ' . $self->get_helo;
		}
		my $relay_info = "[" . $self->get_relay_address() . "]";
		if( $self->get_relay_hostname() ne $relay_info ) {
			$relay_info = $self->get_relay_hostname() . ' ' . $relay_info;
		}
		$header .= ' (' . $relay_info . ')';
	} else {
		$header .= "(from $ENV{USER}\@localhost)";
	}

	my $protocol = $self->get_protocol() || '';

	if( $self->get_local_hostname() ) {
		$header .= "\n\tby " . $self->get_local_hostname();
		if( $protocol =~ /e?smtp/i ) {
			$header .= ' (envelope-sender '
			        . $self->get_sender()
			        . ')';
		}
	}

	if( $self->get_product_name() ) {
		$header .= ' ('
		        . $self->get_product_name()
			. ')';
	}

	if( $protocol =~ /e?smtp/i ) {
		$header .= " with $protocol";
	}

	$header .= ' id ' . $self->get_queue_id();

	# If more than one recipient, don't specify to protect privacy
	if( scalar @{ $self->get_recipients } == 1 ) {
		$header .= "\n\tfor " . $self->get_recipients->[0];
	}

	$header .= '; ' . _format_rfc2822_date( $self->get_timestamp() );

	$self->{received_header} = $header;
}

=head2 get_queue_filename

Return the full path name of this queue file.

Will return undef if no queue ID exists, and die if queue directory is
unset.

=cut

sub get_queue_filename
{
	my ($self) = @_;

	if( ! $self->get_queue_directory ) {
		die q{queue directory not set};
	}

	if( ! $self->get_queue_id ) {
		return undef;
	}

	return File::Spec->catfile( $self->get_queue_directory(), 'qf' . $self->get_queue_id() );
}

=head2 add_recipient ( $recipient [, $recipient, $recipient ] )

Add one or more recipients to this object.

=cut

sub add_recipient
{
	my ($self, @recips) = @_;

	push @{$self->{recipients}}, @recips;
}

=head2 write ( )

Writes a qfXXXXXXX file using the object's data.

A path to create this queue file under must be provided, by first
calling ->set_queue_directory()

=cut

sub write
{
	my ($self) = @_;

	if ( ! $self->get_queue_directory ) {
		die q{write() requires a queue directory};
	}

	my $fh = $self->get_queue_fh;

	if ( ! $fh || ! $fh->opened ) {
		die q{write() cannot write without an open filehandle};
	}

	foreach my $chunk (
		$self->_format_qf_version(),
		$self->_format_create_time(),
		$self->_format_last_processed(),
		$self->_format_times_processed(),
		$self->_format_priority(),
# TODO: Not strictly necessary for delivery, but would be nice to have
#		$self->_format_inode_info(),
		$self->_format_flag_bits(),
		$self->_format_macros(),
		$self->_format_sender_address(),
		$self->_format_recipient_addresses(),
		$self->_format_headers(),
	) {
		if( ! $fh->print( $chunk, "\n" ) ) {
			die q{Couldn't print to } . $self->get_queue_filename . ": $!";
		}
	}

	# TODO: need real return code?
	return 1;
}

=head2 sync ( )

Force any data written to the current filehandle to be flushed to disk.
Returns 1 on success, undef if no queue file is open, and will die on error.

=cut

sub sync
{
	my ($self) = @_;

	my $fh = $self->get_queue_fh;

	if( ! ($fh && blessed $fh && $fh->isa('IO::Handle')) ) {
		return undef;
	}

	if( ! $fh->opened ) {
		return undef;
	}

	if( ! $fh->flush ) {
		carp q{Couldn't flush filehandle!};
	}

	if( ! $fh->sync ) {
		carp q{Couldn't sync filehandle!};
	}

	return 1;
}

=head2 close ( )

Returns true on success, false (as undef) if filehandle doesn't exist
or wasn't open, and dies if closing the filehandle fails.

=cut

sub close
{
	my ($self) = @_;

	my $fh = $self->get_queue_fh;

	if( ! ($fh && blessed $fh && $fh->isa('IO::Handle')) ) {
		return undef;
	}

	if( ! $fh->opened ) {
		return undef;
	}

	if( ! $fh->close ) {
		croak q{Couldn't close filehandle!};
	}

	return 1;
}

=head2 clone ( )

Return a clone of this Sendmail::Queue::Qf object, containing everything EXCEPT:

=over 4

=item * recipients

=item * queue ID

=item * open queue filehandle

=item * synthesized Received: header

=back

=cut
my %skip_for_clone = (
	received_header => 1,
	recipients => 1,
	queue_id   => 1,
	queue_fh   => 1,
);

sub clone
{
	my ($self) = @_;

	my $clone = Sendmail::Queue::Qf->new();


	my @keys = keys %{ $self };

	foreach my $key (@keys) {
		next if exists $skip_for_clone{$key};
		$clone->{$key} = $self->{$key};
	}

	return $clone;
}

=head2 unlink ( ) 

Unlink the queue file.  Returns true (1) on success, false (undef) on
failure.

Unlinking the queue file will only succeed if:

=over 4

=item *

we have a queue directory and queue ID configured for this object

=item * 

the queue file is open and locked

=back

Otherwise, we fail to delete.

=cut

sub unlink
{
	my ($self) = @_;

	if( ! $self->get_queue_filename ) {
		# No filename, can't unlink
		return undef;
	}

	if( ! $self->get_queue_fh ) {
		return undef;
	}

	# Only delete the queue file if we have it locked.
	$self->get_queue_fh->close;
	$self->set_queue_fh(undef);
	if( 1 != unlink($self->get_queue_filename) ) {
		return undef;
	}

	return 1;
}


# Internal methods

sub _format_qf_version
{
	# TODO Bat Book only describes V6!
	return "V8";
}

sub _format_create_time
{
	my ($self) = @_;
	return 'T' . $self->get_timestamp();
}

sub _format_last_processed
{
	return 'K0';
}

sub _format_times_processed
{
	return 'N0';
}

sub _format_priority
{
	my ($self) = @_;

	return 'P' . $self->get_priority();
}

sub _format_inode_info
{
	# TODO: should be major/minor/inode, but we'll leave blank for
	# now
	return 'I';
}

sub _format_flag_bits
{
	# Possible flag bits for V8 queue file:
	# 	8 = Body has 8-bit data (EF_HAS8BIT)
	# 		- TODO figure out how to handle this!
	# 	b = delete Bcc: header (EF_DELETE_BCC)
	# 		- for our purposes, we want to reproduce the
	#  		  Bcc: header in the queued mail.  Future uses
	#  		  of this module may wish to set this to have
	#  		  it removed.
	# 	d = envelope has DSN RET= (EF_RET_PARAM)
	# 	n = don't return body (EF_NO_BODY_RETN)
	# 		- these two work together to set the value of
	# 		  the ${dsn_ret} macro.  If we have both d and
	# 		  n flags, it's equivalent to RET=HDRS, and if
	# 		  we have d and no n flag, it's RET=FULL.  No d
	# 		  and no n means a standard DSN, and no d with
	# 		  n means to suppress the body.
	# 		- TODO: for our purposes we should probably set
	#		  n at all times, and ignore d
	# 	r = response (EF_RESPONSE)
	# 		- this is set if this mail is a bounce,
	# 		  autogenerated return receipt message, or some
	# 		  other return-to-sender type thing.
	# 		- we will avoid setting this, since we're not
	# 		  generating DSNs with this code yet.
	# 	s = split (EF_SPLIT)
	# 		- envelope with multiple recipients has been
	# 		  split into several envelopes
	# 		  (dmo) At this point, I think that this flag
	# 		  means that the envelope has /already/ been
	# 		  split according to number of recipients, or
	# 		  queue groups, or what have you by Sendmail,
	# 		  so we probably want to leave it off.
	# 	w = warning sent (EF_WARNING)
	# 		- message is a warning DSN.  We probably don't
	# 		  want this flag set, but see 'r' flag above.
	# Some details available in $$11.11.7 of the bat book.  Other
	# details require looking at Sendmail sources.
	'F'
}

sub _format_macros
{
	# TODO: we're hardcoding these here, but they really should be
	# generated as needed
	# TODO: we may also want to pass on other macros obtained
	# These are cargo-culted from a test message, and should be
	# researched to determine correct values
	# 	- $r may need to be SMTP or ESMTP
	# 	- ${daemon_flags}EE <-- ???
	# 	- ${daemon_flags}c u <-- ???
	# 	- $_user@hostname <-- ???
	return join("\n",
		'$_localhost.localdomain [127.0.0.1]',
		'$rESMTP',
		'${daemon_flags}',
	);
}

sub _format_sender_address
{
	my ($self) = @_;

	if( ! $self->get_sender() ) {
		die q{No sender address!};
	}
	return 'S<' . $self->get_sender() . '>';
}

sub _format_headers
{
	my ($self) = @_;

	my $out;

	# Ensure we prepend our generated received header, if it
	# exists.
	foreach my $line ( split(/\n/, $self->get_received_header || ''), split(/\n/, $self->get_headers) ) {
		# TODO: proper wrapping of header lines at max length

		# TODO: proper escaping of header data (see Bat Book,
		# ch 25).  We need to be sure that we're not allowing
		# anything that would allow an inbound header to
		# trigger some Sendmail special-case.

		# We do not want any delivery-agent flags between ??.
		# Even Return-Path, which ordinarily has ?P?, we shall
		# ignore flags for, as we want to pass on every header
		# that we originally received.
		# Handle already-wrapped lines properly
		if( $line =~ /^\t/ ) {
			$out .= "$line\n";
		} else {
			$out .=  "H??$line\n";
		}
	}
	$out .= '.';
	return $out;
}

sub _format_recipient_addresses
{
	my ($self) = @_;

	my $recips = $self->get_recipients();
	if( scalar @$recips < 1 ) {
		return;
	}

	my @out;

	foreach my $recip ( @{$recips} ) {
		# TODO: Sanitize $recip before using:
		# 	- make safe (if necessary... does sendmail
		# 	  croak on anything?)
		# 	- remove extra < >

		push @out, "C:<$recip>";
		push @out, "rRFC822; $recip";
		# TODO: flags after R and before : -- which do we need?
		#   P - Primary address.  Addresses via SMTP or
		#       commandline are always considered primary, so yes.
		#   F,D - DSN Notify on failure or delay.  Do we want
		#         DSNs sent for streamed mail?
		# everything else, we can probably ignore
		push @out, "RPFD:$recip";
	}

	return join("\n", @out);
}


1;
__END__


=head1 DEPENDENCIES

=head2 Core Perl Modules

L<Carp>, L<File::Spec>

=head2 Other Modules

L<Class::Accessor::Fast>

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
