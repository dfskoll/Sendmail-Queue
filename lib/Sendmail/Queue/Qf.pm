package Sendmail::Queue::Qf;
use strict;
use warnings;
use Carp;

use Scalar::Util qw(blessed);
use File::Spec;
use IO::File;
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

    $qf->set_defaults();
    $qf->set_sender('me@example.com');
    $qf->add_recipient('you@example.org');

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
	sub _generate_queue_id_template
	{
		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime(time);

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

	sub create_and_lock
	{
		my ($self) = @_;

		if( ! -d $self->get_queue_directory ) {
			die qq{Cannot create queue file without queue directory!};
		}

		# 7th and 8th is random sequence number
		my $seq = int(rand(3600));

		my $tmpl = _generate_queue_id_template();

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
}

=head2 set_defaults ( )

Set default values for any unconfigured qf options.

=cut

sub set_defaults
{
	my ($self) = @_;

	die q{TODO};
}

=head2 get_queue_filename

Return the full path name of this queue file.

Will die if queue directory is unset.

=cut

sub get_queue_filename
{
	my ($self) = @_;

	if( ! $self->get_queue_directory ) {
		die q{queue directory not set};
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

	if( ! $self->get_queue_fh->print( "$data\n" ) ) {
		die q{Couldn't print to } . $self->get_queue_filename . q{: $!};
	}

	# TODO: No, don't do this here.  Should require an explicit
	# close and/or unlock
#	if( ! $self->get_queue_fh->close ) {
#		die qq{Couldn't close $filepath: $!};
#	}

#	warn $data;

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
		carp q{Couldn't close filehandle!};
	}

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
