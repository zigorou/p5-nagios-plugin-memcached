package Nagios::Plugin::Memcached;

use strict;
use warnings;
use parent qw(Nagios::Plugin);

use Carp;
use Cache::Memcached;
use Nagios::Plugin;
use Time::HiRes ();

our $VERSION = '0.01';
our $TIMEOUT = 4;

sub new {
    my $class = shift;

    my %args = (
        shortname => 'MEMCACHED',
        usage     => 'Usage: %s [-H host] [-w warnings] [-c critical] '
          . '[--size-warnng size-warnng] [--size-critical size-critical] '
          . '[--hit-warning hit-warning] [--hit-critical hit-critical] '
          . '[--check-setget]'
          . '[-t timeout] [-v] [-h] [-?] [-V] [--extra-opts section@config_file]',
        version => $VERSION,
        url =>
'http://search.cpan.org/dist/Nagios-Plugin-Memcached/bin/check_memcache',
        license =>
qq|This library is free software, you can redistribute it and/or modify\nit under the same terms as Perl itself.|,
    );

    my $self = $class->SUPER::new(%args);

    $self->setup;

    return $self;
}

sub setup {
    my ($self) = @_;

    $self->setup_args;
}

sub setup_args {
    my ($self) = @_;

    my @args = (
        +{
            spec => 'hosts|H=s@',
            help =>
qq|-H, --hosts=ADDRESS[:PORT] or HOSTNAME[:PORT] or UNIX_SOCKET\n    Available multiple value. default is localhost:11211|
        },
        +{
            spec => 'warning|w=s',
            help =>
qq|-w, --warnings=INTEGER\n   Time threshold on warning. This unit of the value is msec.|
        },
        +{
            spec => 'critical|c=s',
            help =>
qq|-c, --critical=INTEGER\n   Time threshold on critical. This unit of the value is msec.|
        },
        +{
            spec => 'size-warning=s',
            help =>
qq|--size-warning=INTEGER\n   Size threshold on warning. This unit of the value is percent.|
        },
        +{
            spec => 'size-critical=s',
            help =>
qq|--size-critical=INTEGER\n   Size threshold on critical. This unit of the value is percent.|
        },
        +{
            spec => 'hit-warning=s',
            help =>
qq|--hit-warning=INTEGER\n   Hit threshold on warning. This unit of the value is percent.|
        },
        +{
            spec => 'hit-critical=s',
            help =>
qq|--hit-critical=INTEGER\n   Hit threshold on critical. This unit of the value is percent.|
        },
        +{
            spec => 'check-setget=s',
            help =>
qq|--check-getset=STRING\n    Try set key-value and get key. The argument is treats as key.|
        },
    );

    $self->add_arg(%$_) for (@args);
}

sub run {
    my ($self) = @_;

    $self->getopts;

    my $hosts = $self->opts->get("hosts");

    unless ($hosts) {
        $hosts ||= ["localhost:11211"];
    }

    $hosts = [ map { $self->normalize_host($_) } @$hosts ];
    $self->opts->set( "hosts", $hosts );

    my @runmodes = $self->detect_runmodes;

    #    if (@runmodes == 0) {
    #        $self->nagios_exit(UNKNOWN, 'Not running any check.');
    #        return;
    #    }

    $self->add_message( OK, "OK" );

    eval {
        my $timeout = $self->opts->get("timeout") || $TIMEOUT;

        local $SIG{ALRM} = sub {
            $self->add_message( CRITICAL, "Timeout $timeout sec." );
            croak("Timeout $timeout sec");
        };

        alarm $timeout;

        my $cache = Cache::Memcached->new( { servers => $hosts } );

        $cache->set_cb_connect_fail(
            sub {
                my $prefip = shift;
                $self->add_message( CRITICAL, "Can't connect to $prefip" );
                croak("Can't connect to $prefip");
            }
        );

        my $begin = [Time::HiRes::gettimeofday];
        my $stats = $cache->stats( [qw/misc/] );
        $stats->{time} =
          Time::HiRes::tv_interval( $begin, [Time::HiRes::gettimeofday] );

        for my $runmode (@runmodes) {
            my $method = $runmode->{name};
            $self->$method( $cache, $stats, $runmode->{args} );
        }

        alarm 0;
    };
    if ( $@ && $@ !~ /(Timeout \d+ sec|Can't connect to)/ ) {
        $self->add_message( CRITICAL, join( " ", split( "\n", $@ ) ) );
    }

    $self->nagios_exit( $self->check_messages( join => ", " ) );
    return;
}

sub check_time {
    my ( $self, $cache, $stats, $args ) = @_;

    $self->add_message( OK, "Time checked: OK" );

    my $code = $self->check_threshold(
        check    => $stats->{time} * 1000,
        warning  => $args->{warning},
        critical => $args->{critical}
    );

    $self->add_message( $code, "Time checked: NG" ) if ( $code > OK );

    $self->add_perfdata(
        label     => 'time',
        value     => sprintf( "%.4f", $stats->{time} * 1000 ),
        uom       => 'msec',
        threshold => $self->threshold
    );
}

sub check_size {
    my ( $self, $cache, $stats, $args ) = @_;

    for my $host ( keys %{ $stats->{hosts} } ) {
        my $host_stats = $stats->{hosts}{$host}{misc};

        $self->add_message( OK, "Size checked; OK - at $host" );

        my $use_size =
          $host_stats->{bytes} * 100 / $host_stats->{limit_maxbytes};

        my $code = $self->check_threshold(
            check    => $use_size,
            warning  => $args->{warning},
            critical => $args->{critical}
        );

        $self->add_message( $code, "Size checked: NG - at $host" )
          if ( $code > OK );

        $self->add_perfdata(
            label     => 'size',
            value     => sprintf( "%.2f", $use_size ),
            uom       => '%',
            threshold => $self->threshold
        );
    }
}

sub check_hit {
    my ( $self, $cache, $stats, $args ) = @_;

    for my $host ( keys %{ $stats->{hosts} } ) {
        my $host_stats = $stats->{hosts}{$host}{misc};

        if ( $host_stats->{cmd_get} == 0 ) {
            $self->add_message( OK,
                "Hit checked: OK - stats cmd_get is zero at $host" );
            next;
        }

        $self->add_message( OK, "Hit checked: OK - at $host" );

        my $hits = $host_stats->{get_hits} * 100 / $host_stats->{cmd_get};

        my $code = $self->check_threshold(
            check   => $hits,
            warning => sprintf( '@%d:%d', $args->{critical}, $args->{warning} ),
            critical => sprintf( '@0:%d', $args->{critical} )
        );

        $self->add_message( $code, "Hit checked: NG - at $host" )
          if ( $code > OK );

        $self->add_perfdata(
            label     => 'hits',
            value     => sprintf( "%.2f", $hits ),
            uom       => '%',
            threshold => $self->threshold
        );
    }
}

sub check_setget {
    my ( $self, $cache, $stats, $args ) = @_;
    my $key   = $args->{key};
    my $value = time;

    eval {
        $cache->set( $key => $value );
        my $rv = $cache->get($key);
        if ( defined $rv && $rv eq $value ) {
            $self->add_message( OK,
                sprintf(
                    'SetGet checked: OK - key: %s, value: %s',
                    $key, $value
                )
            );
        }
        else {
            $self->add_message( CRITICAL,
                sprintf(
                    'SetGet checked: NG - key: %s, value: %s, rv: %s',
                    $key, $value, defined $rv ? $rv : 'undefined'
                )
            );
        }
    };
    if ($@) {
        $self->add_message( CRITICAL,
            sprintf(
                'SetGet checked: NG - key: %s, value: %s, error: %s',
                $key, $value, defined $@ ? $@ : ''
            )
        );
    }
}

sub detect_runmodes {
    my ($self) = @_;

    my @runmodes = ();
    my $opts     = $self->opts;

    if ( defined $opts->get("warning") && defined $opts->get("critical") ) {
        if ( $opts->get("warning") > $opts->get("critical") ) {
            $self->nagios_exit( UNKNOWN,
                "Invalid arguments - warning > critical" );
        }

        push(
            @runmodes,
            {
                name => 'check_time',
                args => {
                    warning  => $opts->get("warning"),
                    critical => $opts->get("critical"),
                    key      => $opts->get("key")
                }
            }
        );
    }

    if (   $opts->get("hosts")
        && @{ $opts->get("hosts") } == 1
        && defined $opts->get("size-warning")
        && defined $opts->get("size-critical") )
    {
        if ( $opts->get("size-warning") > $opts->get("size-critical") ) {
            $self->nagios_exit( UNKNOWN,
                "Invalid arguments - size-warning > size-critical" );
        }

        push(
            @runmodes,
            {
                name => "check_size",
                args => {
                    warning  => $opts->get("size-warning"),
                    critical => $opts->get("size-critical"),
                    host     => $opts->get("hosts")->[0]
                }
            }
        );
    }

    if (   defined $opts->get("hit-warning")
        && defined $opts->get("hit-critical") )
    {
        if ( $opts->get("hit-warning") < $opts->get("hit-critical") ) {
            $self->nagios_exit( UNKNOWN,
                "Invalid arguments - hit-warning < hit-critical" );
        }

        push(
            @runmodes,
            {
                name => "check_hit",
                args => {
                    warning  => $opts->get("hit-warning"),
                    critical => $opts->get("hit-critical"),
                }
            }
        );
    }

    if ( defined $opts->get('check-setget')
        && length $opts->get('check-setget') )
    {
        push(
            @runmodes,
            {
                name => "check_setget",
                args => { key => $opts->get('check-setget'), }
            }
        );
    }

    return @runmodes;
}

sub normalize_host {
    my ( $proto, $host ) = @_;
    return ( $host =~ /:\d+$/ ) ? $host : "$host:11211";
}

__END__

=head1 NAME

Nagios::Plugin::Memcached - Nagios plugin to observe memcached.

=head1 VERSION

version 0.01

=head1 SYNOPSIS

  use Nagios::Plugin::Memcached;

  my $np = Nagios::Plugin::Memcached->new;
  $np->run;

=head1 DESCRIPTION

Please setup your nagios config.

  ### check response time(msec) for memcached
  define command {
    command_name    check_memcached_response
    command_line    /usr/bin/check_memcached -H $HOSTADDRESS$ -w 3 -c 5
  }

  ### check cache size ratio(bytes/limit_maxbytes[%]) for memcached
  define command {
    command_name    check_memcached_size
    command_line    /usr/bin/check_memcached -H $HOSTADDRESS$ --size-warning 60 --size-critical 80
  }

  ### check cache hit ratio(get_hits/cmd_get[%]) for memcached
  define command {
    command_name    check_memcached_hit
    command_line    /usr/bin/check_memcached -H $HOSTADDRESS$ --hit-warning 40 --hit-critical 20
  }

This plugin can execute with all threshold options together.

=head2 Command Line Options

Usage for L<check_memcached> command.

  Usage: check_memcached [-H host] [-w warnings] [-c critical] [--size-warnng size-warnng] [--size-critical size-critical] [--hit-warning hit-warning] [--hit-critical hit-critical] [-t timeout] [-v] [-h] [-?] [-V] [--extra-opts section@config_file]
  
   -?, --usage
     Print usage information
   -h, --help
     Print detailed help screen
   -V, --version
     Print version information
   --extra-opts=[<section>[@<config_file>]]
     Section and/or config_file from which to load extra options (may repeat)
   -H, --hosts=ADDRESS[:PORT] or HOSTNAME[:PORT] or UNIX_SOCKET
      Available multiple value. default is localhost:11211
   -w, --warnings=INTEGER
     Time threshold on warning. This unit of the value is msec.
   -c, --critical=INTEGER
     Time threshold on critical. This unit of the value is msec.
   --size-warning=INTEGER
     Size threshold on warning. This unit of the value is percent.
   --size-critical=INTEGER
     Size threshold on critical. This unit of the value is percent.
   --hit-warning=INTEGER
     Hit threshold on warning. This unit of the value is percent.
   --hit-critical=INTEGER
     Hit threshold on critical. This unit of the value is percent.
   -t, --timeout=INTEGER
     Seconds before plugin times out (default: 15)
   -v, --verbose
     Show details for command-line debugging (can repeat up to 3 times)

=head1 PROPERTIES

=head2 $TIMEOUT(=4)

Default value of connection timeout(sec) between the memcached server.

=head1 METHODS

=head2 new()

create instance.

=head2 setup()

setup this plugin.

=head2 setup_args()

setup arguments.

=head2 run()

run checks.

=head2 check_time($cache, $stats, $args)

check execute times of stats.

=head2 check_size($cache, $stats, $args)

check using bytes ratio.

=head2 check_hit($cache, $stats, $args)

check cache hit ratio.

=head2 detect_runmodes

Detecting runmode.

=head2 normalize_host

Add default port(11211) if not exists specified port.

=head1 AUTHOR

Toru Yamaguchi, C<< <zigorou@cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-nagios-plugins-memcached@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.  I will be notified, and then you'll automatically be
notified of progress on your bug as I make changes.

=head1 COPYRIGHT & LICENSE

Copyright 2007 Toru Yamaguchi, All Rights Reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;    # End of Nagios::Plugin::Memcached
