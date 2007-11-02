package Sendmail::Queue::Qf;
use strict;
use warnings;
use Carp;

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

	# TODO: need get/set methods for these
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

sub generate_queue_id
{
	my ($self) = @_;

	die q{TODO};
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
