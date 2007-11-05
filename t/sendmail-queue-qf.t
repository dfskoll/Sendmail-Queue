use strict;
use warnings;
use Test::More tests => 10;
use Test::Exception;
use File::Temp;

BEGIN { 
	use_ok('Sendmail::Queue::Qf'); 
}

# Constructor
{
	my $qf = Sendmail::Queue::Qf->new();
	isa_ok( $qf, 'Sendmail::Queue::Qf');
}

# Setting of queue ID manually
{
	my $qf = Sendmail::Queue::Qf->new();
	$qf->set_queue_id( 'wookie' );
	is( $qf->get_queue_id(), 'wookie', 'Got the queue ID we set');
}

# Generation of queue ID
{
	my $qf = Sendmail::Queue::Qf->new();
	my $qid = $qf->generate_queue_id();
	is( $qid, $qf->get_queue_id(), 'generate_queue_id() properly saved our queue id');
	like( $qf->get_queue_id(), qr/^[0-9A-Za-x]{8}[0-9]{6}$/, 'Queue ID looks reasonably sane');
}

# Generation of queue ID with directory provided
{
	my $qf = Sendmail::Queue::Qf->new();
	
	my $dir = File::Temp::tempdir( CLEANUP => 1 );

	$qf->set_queue_directory( $dir );

	my $qid = $qf->generate_queue_id();
	is( $qid, $qf->get_queue_id(), 'generate_queue_id() properly saved our queue id');
	like( $qf->get_queue_id(), qr/^[0-9A-Za-x]{8}[0-9]{6}$/, 'Queue ID looks reasonably sane');

	my $count = 0;
	my $existing_file = "$dir/foo";
	open(FH,">$existing_file") or die $!;
	close FH;
	no warnings 'once';
	local *File::Spec::catfile = sub {
		if( $count++ < 3 ) {
			return $existing_file;
		}
		return "$dir/new_file";
	};

	my $warn_count = 0;
	{

		local $SIG{__WARN__} = sub { 
			if( $_[0] =~ /exists, incrementing sequence/ ) { 
				$warn_count++;
				return;
			}
			warn $_[0] 
		};
		$qid = $qf->generate_queue_id();
	}
	is( $warn_count, 3, 'Got 3 warnings about duplicate filename');
	is( $qid, $qf->get_queue_id(), 'generate_queue_id() properly saved our queue id');
	like( $qf->get_queue_id(), qr/^[0-9A-Za-x]{8}[0-9]{6}$/, 'Queue ID looks reasonably sane');
}
