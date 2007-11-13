use strict;
use warnings;
use Test::More tests => 4;
use Test::Exception;
use File::Temp;
use File::Slurp;

BEGIN { 
	use_ok('Sendmail::Queue'); 
}

# Constructor
{
	my $qf = Sendmail::Queue->new({
		QueueDirectory => 't/tmp',
	});
	isa_ok( $qf, 'Sendmail::Queue');
}

# queue_message()
{

	my $dir = 't/tmp';

	my $queue = Sendmail::Queue->new({
		QueueDirectory => $dir,
	});

	# Override so that our test will work
	no warnings 'redefine';
	local *Sendmail::Queue::Qf::_format_create_time = sub { 'T1234567890' };

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
		data => $data
	});

	my $qf_expected = <<'EOM';
V8
T1234567890
K0
N0
P30000
Fs
$_localhost.localdomain [127.0.0.1]
$rESMTP
${daemon_flags}
S<dmo@dmo.ca>
C:<dmo@roaringpenguin.com>
rRFC822; dmo@roaringpenguin.com
RPFD:dmo@roaringpenguin.com
C:<dfs@roaringpenguin.com>
rRFC822; dfs@roaringpenguin.com
RPFD:dfs@roaringpenguin.com
H??From: foobar
H??To: someone
H??Date: Wed, 07 Nov 2007 14:54:33 -0500
.
EOM

	my $df_expected =<<'EOM';
Test message
-- 
Dave
EOM

	is( File::Slurp::slurp( "$dir/qf$qid" ), $qf_expected, 'Wrote expected qf data');
	is( File::Slurp::slurp( "$dir/df$qid" ), $df_expected, 'Wrote expected df data');

}
