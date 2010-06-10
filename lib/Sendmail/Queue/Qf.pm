package Sendmail::Queue::Qf;
use strict;
use warnings;
use Carp;

use Scalar::Util qw(blessed);
use File::Spec;
use IO::File;
use Time::Local ();
use Fcntl qw( :flock );
use Errno qw( EEXIST );
use Mail::Header::Generator ();

## no critic 'ProhibitMagicNumbers'

# TODO: testcases:
#  - header lines too long
#  - 8-bit body handling
#  - total size of headers > 32768 bytes
#  - weird/missing sender and recipient addresses
#  - streaming multiple copies as fast as possible

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
	qf_version
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

    $qf->write( );

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
		headers        => '',
		recipients     => [],
		product_name   => 'Sendmail::Queue',
		local_hostname => 'localhost',
		timestamp      => time,
		priority       => 30000,

		# This code generates V6-compatible qf files to work
		# with Sendmail 8.12.
		qf_version     => '6',
		%{ $args || {} }, };

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

Note that we create the qf file directly, rather than creating an
intermediate tf file and renaming aftewards.  This is all good and well
for creating /new/ qf files -- sendmail does it that way as well -- but
if we ever want to rewrite one, it's not safe.

=cut

sub create_and_lock
{
	my ($self) = @_;

	if( ! -d $self->get_queue_directory ) {
		die q{Cannot create queue file without queue directory!};
	}

	# 7th and 8th is random sequence number
	my $seq = int(rand(3600));

	my $tmpl = _generate_queue_id_template( $self->get_timestamp );

	my $iterations = 0;
	while( ++$iterations < 3600 ) {
		my $qid  = _fill_template($tmpl, $seq);
		my $path = File::Spec->catfile( $self->{queue_directory}, "qf$qid" );

		# TODO: make sure a queue run won't delete it if empty
		# and unlocked.
		# TODO: also, if queue runner locks before reading, we
		# could fail our lock.  More testing!
		# Also, document what Sendmail does in that case, so we
		# don't forget it in 3 months...
		my $old_umask = umask(002);
		my $fh = IO::File->new( $path, O_RDWR|O_CREAT|O_EXCL );
		umask($old_umask);
		if( $fh ) {
			if( ! flock $fh, LOCK_EX | LOCK_NB ) {
				die qq{Couldn't lock $path: $!};
			}
			$self->set_queue_id( $qid );
			$self->set_queue_fh( $fh  );
			last;
		} elsif( $! == EEXIST ) {
			# Try the next one
			$seq = ($seq + 1) % 3600;
		} else {
			die qq{Error creating qf file $path: $!};
		}

	}

	if ($iterations >= 3600 ) {
		die q{Could not create queue file; too many iterations};
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

	sprintf '%s, %d %s %d %02d:%02d:%02d %s%02d%02d',
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

	my $g = Mail::Header::Generator->new();

	$self->{received_header} = $g->received({
		helo => $self->get_helo(),
		hostname => $self->get_local_hostname(),
		product_name => $self->get_product_name(),
		protocol => ($self->get_protocol || ''),
		queue_id  => $self->get_queue_id(),
		recipients => $self->get_recipients(),
		relay_address => $self->get_relay_address(),
		relay_hostname => $self->get_relay_hostname(),
		sender   => $self->get_sender(),
		timestamp => $self->get_timestamp(),
		user => $ENV{USER},
	});

	return $self->{received_header};
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
		$self->_format_flag_bits(),
		$self->_format_macros(),
		$self->_format_sender_address(),
		$self->_format_recipient_addresses(),
		$self->_format_headers(),
		$self->_format_end_of_qf(),
	) {
		if( ! $fh->print( $chunk, "\n" ) ) {
			die q{Couldn't print to } . $self->get_queue_filename . ": $!";
		}
	}

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

	if( ! $fh->opened ) {
		return undef;
	}

	if( ! $fh->flush ) {
		croak q{Couldn't flush filehandle!};
	}

	if( ! $fh->sync ) {
		croak q{Couldn't sync filehandle!};
	}

	return 1;
}

=head2 close ( )

Returns true on success, false (as undef) if filehandle doesn't exist
or wasn't open, and dies if closing the filehandle fails.

=cut

# TODO: toss exceptions for everything?
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
	sender => 1,
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

	# Only delete the queue file if we have it locked.  Thus, we
	# must call unlink() before close(), or we're no longer holding
	# the lock.
	if( 1 != unlink($self->get_queue_filename) ) {
		return undef;
	}
	$self->get_queue_fh->close;
	$self->set_queue_fh(undef);

	return 1;
}


# Internal methods

sub _format_qf_version
{
	my ($self) = @_;
	return 'V' . $self->get_qf_version();
}

sub _format_create_time
{
	my ($self) = @_;
	return 'T' . $self->get_timestamp();
}

sub _format_last_processed
{
	# Never processed, so zero.
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
	# 		- We will avoid setting this one for now, as
	# 		  whether or not to return headers should be a
	# 		  site policy decision.
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
	my ($self) = @_;

	my @macros;

	# TODO: we may also want to pass on other macros

	# $r macro - protocol by which message was received
	my $protocol = $self->get_protocol() || '';
	if( $protocol =~ /^e?smtp$/i ) {
		push @macros, '$r' . uc($protocol);
	}

	# ${daemon_flags} macro - shouldn't need any of these, so set a
	# blank one.
	push @macros, '${daemon_flags}';

	return join("\n", @macros);
}

sub _format_sender_address
{
	my ($self) = @_;

	if( ! defined $self->get_sender() ) {
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
		# Sendmail will happily deal with over-length lines in
		# a queue file when transmitting, by breaking each line
		# after 998 characters (to allow for \r\n under the
		# 1000 character RFC limit) and splitting into a new
		# line.  We may wish to do this ourselves in a
		# nicer way, perhaps by adding a continuation \n\t at
		# the first whitespace before 998 characters.

		# It doesn't appear that we need to escape any possible
		# ${whatever} macro expansion in H?? lines, based on
		# tests using 8.13.8 queue files.

		# We do not want any delivery-agent flags between ??.
		# Even Return-Path, which ordinarily has ?P?, we shall
		# ignore flags for, as we want to pass on every header
		# that we originally received.
		if( $line =~ /^\s/ ) {
			# Handle already-wrapped lines properly, by
			# appending them as-is.  Wrapped lines can
			# begin with any whitespace, but it's most
			# commonly a tab.
			$out .= "$line\n";
		} else {
			$out .=  "H??$line\n";
		}
	}

	# Don't want a trailing newline
	chomp $out;

	return $out;
}

sub _format_end_of_qf
{
	my ($self) = @_;

	# Dot signifies end of queue file.  
	return '.';
}

sub _format_recipient_addresses
{
	my ($self) = @_;

	my $recips = $self->get_recipients();
	if( scalar @$recips < 1 ) {
		return;
	}

	# TODO: consistency - some methods append to string, others
	# push to array and join.  Use one or the other.
	my @out;

	foreach my $recip ( @{$recips} ) {

		# Sanitize $recip a little before using it.
		# First, remove any leading/trailing whitespace, and
		# any < > that might be present already
		#
		# TODO: do we need to do any other validation or
		# cleaning of address here?
		# TODO: why here, and not for sender?  Should probably
		# separate this out to a canonicalize() method and do
		# it for both.  Do it in add_recipient and set_sender
		# instead.
		$recip =~ s/^[<\s]+//;
		$recip =~ s/[>\s]+$//;

		push @out, "C:<$recip>";
		push @out, "rRFC822; $recip";


		# R line: R<flags>:<recipient>
		# Possible flags:
		#   P - Primary address.  Addresses via SMTP or
		#       commandline are always considered primary, so
		#       we need this flag.
		#   S,F,D - DSN Notify on success, failure or delay.
		#       We may not want this notification for the
		#       client queue, but current injection with
		#       sendmail binary does add FD, so we will do so
		#       here.
		#   N - Flag says whether or not notification was
		#       enabled at SMTP time with the NOTIFY extension.
		#       If not enabled, S, F and D have no effect.
		#   A - address is result of alias expansion.  No,
		#       we don't want this
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

Dave O'Neill, C<< <support at roaringpenguin.com> >>

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2007 Roaring Penguin Software, Inc.  All rights reserved.
