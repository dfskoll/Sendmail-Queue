package Sendmail::Queue::Qf;
use strict;
use warnings;
use Carp;

use File::Spec;
use IO::File;
use Fcntl qw( :flock );

use base qw(Class::Accessor::Fast);
__PACKAGE__->follow_best_practice;
__PACKAGE__->mk_accessors( qw(
	queue_id
	queue_directory
	sender
	recipients
	headers
) );

=head1 NAME

Sendmail::Queue::Qf - Represent a Sendmail qfXXXXXXXX (control) file

=head1 SYNOPSIS

    use Sendmail::Queue::Qf;

    # Create a new qf file object
    my $qf = Sendmail::Queue::Qf->new();

    # Generate a Sendmail 8.12-compatible queue ID
    $qf->generate_queue_id();
    $qf->set_defaults();
    $qf->set_sender('me@example.com');
    $qf->add_recipient('you@example.org');

    $qf->write( '/path/to/queue');

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
		queue_directory => undef,
		queue_id => undef,
		sender => undef,
		recipients => [],
	};

	bless $self, $class;

	return $self;
}

=head2 generate_queue_id ( )

Generate a Sendmail 8.12-compatible queue ID for this qf file.

See Bat Book 3rd edition, section 11.2.1

=cut

{
	my @base_60_chars = ( 0..9, 'A'..'Z', 'a'..'x' );
	sub generate_queue_id
	{
		my ($self) = @_;

		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime(time);

		# First char is year minus 1900, mod 60
		# (perl's localtime conveniently gives us the year-1900 already)
		# 2nd and 3rd are month, day
		# 4th through 6th are hour, minute, second
		my $qid = join('', @base_60_chars[
			$year % 60,
			$mon,
			$mday,
			$hour,
			$min,
			$sec
		]);

		# 7th and 8th is random sequence number
		my $seq = int( rand(3600) );

		# PID is 9th through 14th
		my $pid = sprintf('%06d', $$);

		# This is not great... we want to avoid name
		# collisions, but:
		#   - we can only do so if queue_directory is already set
		#   - it's a huge race condition anyway
		#   - with the PID in the name, a single-threaded app
		#     creating less than one per second shouldn't be
		#     able to have a collision
		# so, we just try our best with the info we have and
		# hope it's good enough.
		my $full_qid = $qid
			. $base_60_chars[ int($seq / 60) ]
			. $base_60_chars[ $seq % 60 ]
			. $pid;
		if( $self->{queue_directory} && -d $self->{queue_directory} ) {
			my $path = undef;
			while( ! $path || -e $path ) {
				if( $path ) {
					warn "$path exists, incrementing sequence";
				}
				$seq = ($seq + 1) % 360;
				$full_qid = $qid
					. $base_60_chars[ int($seq / 60) ]
					. $base_60_chars[ $seq % 60 ]
					. $pid;
				$path = File::Spec->catfile( $self->{queue_directory}, $full_qid );
			}

		}

		return $self->set_queue_id( $full_qid );
	}
}

=head2 set_defaults ( )

Set default values for any unconfigured qf options.

=cut

sub set_defaults
{
	my ($self) = @_;

	die q{TODO};
}

sub get_queue_filename
{
	my ($self) = @_;

	return File::Spec->catfile( $self->get_queue_directory(), 'qf' . $self->get_queue_id() );
}

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

	if( ! $self->get_queue_id() ) {
		$self->generate_queue_id();
	}

	my $filepath = $self->get_queue_filename();

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

	# TODO: should print directly instead of creating a copy in
	# $data
	my $data = join("\n",
		$self->_format_qf_version(),
		$self->_format_create_time(),
		$self->_format_last_processed(),
		$self->_format_times_processed(),
		$self->_format_priority(),
# Not strictly necessary for delivery, but would be nice to have
#		$self->_format_inode_info(),
		$self->_format_flag_bits(),
		$self->_format_macros(),
		$self->_format_sender_address(),
		$self->_format_recipient_addresses(),
		$self->_format_headers(),
	);

	if( ! $fh->print( "$data\n" ) ) {
		die qq{Couldn't print to $filepath: $!};
	}

	if( ! $fh->close ) {
		die qq{Couldn't close $filepath: $!};
	}

#	warn $data;

	# TODO: need real return code?
	return 1;
}

sub _format_qf_version
{
	# Bat Book only describes V6!
	return "V8";
}

sub _format_create_time
{
	return 'T' . time;
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
	# TODO: should be adjustable
	return 'P30000';
}

sub _format_inode_info
{
	# TODO: should be major/minor/inode, but we'll leave blank for
	# now
	return 'I';
}

sub _format_flag_bits
{
	# TODO: $$11.11.7 in bat book.  Unknown if we need this, but
	# all samples seem to have it
	# 	- some also have the w and b flags.  Look into this.
	'Fs'
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

	my @out;
	foreach my $line ( split /\s*\n\s*/, $self->get_headers ) {
		# TODO: proper wrapping of header lines

		# TODO: proper escaping of header data (see Bat Book,
		# ch 25).  We need to be sure that we're not allowing
		# anything that would allow an inbound header to
		# trigger some Sendmail special-case.

		# We do not want any delivery-agent flags between ??.
		# Even Return-Path, which ordinarily has ?P?, we shall
		# ignore flags for, as we want to pass on every header
		# that we originally received.
		push @out, "H??$line";
	}
	push @out, '.';
	return join("\n", @out);
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
		# TODO: Sanitize $recip before using ?

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
