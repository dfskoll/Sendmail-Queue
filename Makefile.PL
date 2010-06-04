use inc::Module::Install;

name     'Sendmail-Queue';
all_from 'lib/Sendmail/Queue.pm';
license  'gpl';

requires 'File::Spec';
requires 'IO::File';
requires 'Scalar::Util';
requires 'Time::Local';
requires 'Class::Accessor::Fast';
requires 'Mail::Header::Generator';

build_requires 'Test::More';

WriteAll;
