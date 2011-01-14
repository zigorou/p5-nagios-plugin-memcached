use Test::More tests => 1;

BEGIN {
    use_ok('Nagios::Plugin::Memcached');
}

diag( "Testing Nagios::Plugin::Memcached $Nagios::Plugin::Memcached::VERSION" );
