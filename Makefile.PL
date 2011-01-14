use inc::Module::Install;

name 'Nagios-Plugin-Memcached';
all_from 'lib/Nagios/Plugin/Memcached.pm';
license 'perl';

requires 'Carp';
requires 'Cache::Memcached';
requires 'FindBin';
requires 'Nagios::Plugin';
requires 'Time::HiRes';

tests 't/*.t';
author_tests 'xt';

install_script 'bin/check_memcached';

test_requires 'Test::More';

auto_set_repository;
auto_include;
auto_install;

WriteAll;
