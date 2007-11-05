package Sendmail::Queue::Qf;
use strict;
use warnings;
use Carp;

use File::Spec;

use base qw(Class::Accessor::Fast);
__PACKAGE__->follow_best_practice;
__PACKAGE__->mk_accessors( qw(
	queue_id
	queue_directory
	sender
	recipients
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
		$self->{queue_id} = $full_qid;

		return $self->{queue_id};

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
