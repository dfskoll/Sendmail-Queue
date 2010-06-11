package test_queue;
use strict;
use warnings;

use base qw( Test::Class );

use Test::Most;
use File::Temp;
use File::Slurp;

use Sendmail::Queue;

sub test_constructor : Test(1)
{
	my $qf = Sendmail::Queue->new({
		queue_directory => 't/tmp',
	});
	isa_ok( $qf, 'Sendmail::Queue');
}

# queue_message()
sub queue_message : Test(4)
{

	my $dir = 't/tmp';

	my $queue = Sendmail::Queue->new({
		queue_directory => $dir,
	});

	my $data = <<EOM;
From: foobar
To: someone
Date: Wed, 07 Nov 2007 14:54:33 -0500

Test message
-- 
Dave
EOM

	my $qid = $queue->queue_message({
		sender => 'dmo@dmo.ca',
		recipients => [
			'dmo@roaringpenguin.com',
			'dfs@roaringpenguin.com',
		],
		data => $data,
		timestamp => 1234567890,
		protocol => 'ESMTP',
	});

	my $qf_regex = qr/^V6
T1234567890
K0
N0
P30000
F
\$rESMTP
\${daemon_flags}
S<dmo\@dmo.ca>
C:<dmo\@roaringpenguin.com>
rRFC822; dmo\@roaringpenguin.com
RPFD:dmo\@roaringpenguin.com
C:<dfs\@roaringpenguin.com>
rRFC822; dfs\@roaringpenguin.com
RPFD:dfs\@roaringpenguin.com
H\?\?Received: \(from dmo\@localhost\)
	by localhost \(envelope-sender dmo\@dmo\.ca\) \(Sendmail::Queue\) with ESMTP id n1DNVU..\d{6}; Fri, 13 Feb 2009 18:31:30 -0500
H\?\?From: foobar
H\?\?To: someone
H\?\?Date: Wed, 07 Nov 2007 14:54:33 -0500
.
$/;

	my $df_expected =<<'EOM';
Test message
-- 
Dave
EOM

	like( File::Slurp::slurp( "$dir/qf$qid" ), $qf_regex, 'Wrote expected qf data');
	is( File::Slurp::slurp( "$dir/df$qid" ), $df_expected, 'Wrote expected df data');

	is( unlink(<$dir/qf*>), 1, 'Unlinked one queue file');
	is( unlink(<$dir/df*>), 1, 'Unlinked one data file');

}

sub queue_multiple_success : Test(10)
{

	my $dir = 't/tmp';

	my $queue = Sendmail::Queue->new({
		queue_directory => $dir,
	});

	my $data = <<EOM;
From: foobar
To: someone
Date: Wed, 07 Nov 2007 14:54:33 -0500

Test message
-- 
Dave
EOM

	my $qids;
	lives_ok {
		$qids = $queue->queue_multiple({
			envelopes => {
				stream_one => {
					sender => 'dmo@dmo.ca',
					recipients => [
					'dmo@roaringpenguin.com',
					'dfs@roaringpenguin.com',
					],
				},
				stream_two => {
					sender => 'dmo@dmo.ca',
					recipients => [
						'foo@roaringpenguin.com',
						'bar@roaringpenguin.com',
					],
				},
			},
			data => $data,
			timestamp => 1234567890,
			protocol => 'ESMTP',
		});
	} '->queue_multiple() lives';

	cmp_deeply( [ keys %$qids ], bag( qw(stream_one stream_two) ), 'Got a qid for all sets');

	my $qf_one_regex = qr/^V6
T1234567890
K0
N0
P30000
F
\$rESMTP
\${daemon_flags}
S<dmo\@dmo.ca>
C:<dmo\@roaringpenguin.com>
rRFC822; dmo\@roaringpenguin.com
RPFD:dmo\@roaringpenguin.com
C:<dfs\@roaringpenguin.com>
rRFC822; dfs\@roaringpenguin.com
RPFD:dfs\@roaringpenguin.com
H\?\?Received: \(from dmo\@localhost\)
	by localhost \(envelope-sender dmo\@dmo\.ca\) \(Sendmail::Queue\) with ESMTP id n1DNVU..\d{6}; Fri, 13 Feb 2009 18:31:30 -0500
H\?\?From: foobar
H\?\?To: someone
H\?\?Date: Wed, 07 Nov 2007 14:54:33 -0500
.
$/;

	my $qf_two_regex = qr/^V6
T1234567890
K0
N0
P30000
F
\$rESMTP
\${daemon_flags}
S<dmo\@dmo.ca>
C:<foo\@roaringpenguin.com>
rRFC822; foo\@roaringpenguin.com
RPFD:foo\@roaringpenguin.com
C:<bar\@roaringpenguin.com>
rRFC822; bar\@roaringpenguin.com
RPFD:bar\@roaringpenguin.com
H\?\?Received: \(from dmo\@localhost\)
	by localhost \(envelope-sender dmo\@dmo\.ca\) \(Sendmail::Queue\) with ESMTP id n1DNVU..\d{6}; Fri, 13 Feb 2009 18:31:30 -0500
H\?\?From: foobar
H\?\?To: someone
H\?\?Date: Wed, 07 Nov 2007 14:54:33 -0500
.
$/;

	my $df_expected =<<'EOM';
Test message
-- 
Dave
EOM

	isnt( $qids->{stream_one}, $qids->{stream_two}, 'Got two different queue IDs');

	like( File::Slurp::slurp( "$dir/qf$qids->{stream_one}" ), $qf_one_regex, 'Wrote expected qf data');
	like( File::Slurp::slurp( "$dir/qf$qids->{stream_two}" ), $qf_two_regex, 'Wrote expected qf data');
	is( File::Slurp::slurp( "$dir/df$qids->{stream_one}" ), $df_expected, 'Wrote expected df data');
	is( File::Slurp::slurp( "$dir/df$qids->{stream_two}" ), $df_expected, 'Wrote expected df data for stream two');

	# TODO: stat each of the files and make sure the inode num is the same

	is( (stat("$dir/df$qids->{stream_one}"))[3], 2, 'nlink is 2 on df file');

	is( unlink(<$dir/qf*>), 2, 'Unlinked two queue files');
	is( unlink(<$dir/df*>), 2, 'Unlinked two data files');
}

sub queue_message_failure : Test(6)
{

	my $dir = 't/tmp';

	my $queue = Sendmail::Queue->new({
		queue_directory => $dir,
	});

	my $data = <<EOM;
From: foobar
To: someone
Date: Wed, 07 Nov 2007 14:54:33 -0500

Test message
-- 
Dave
EOM

	chmod 0555, $dir;

	dies_ok {
	my $qid = $queue->queue_message({
		sender => 'dmo@dmo.ca',
		recipients => [
			'dmo@roaringpenguin.com',
			'dfs@roaringpenguin.com',
		],
		data => $data,
		timestamp => 1234567890,
	}); } 'queue_message() dies';

	chmod 0755, $dir;

	like( $@, qr{Error creating qf file t/tmp/qfn1DNVU..\d{6}: Permission denied}, 'Got expected error');

	my @qf = <$dir/qf*>;
	my @df = <$dir/df*>;

	is( scalar @qf, 0, 'No qf files');
	is( scalar @df, 0, 'No df files');

	is( unlink(<$dir/qf*>), 0, 'Cleanup unlinked no queue files');
	is( unlink(<$dir/df*>), 0, 'Cleanup unlinked no data files');
}

__PACKAGE__->runtests unless caller();
