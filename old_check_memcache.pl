#!/usr/bin/perl -w
# nagios: -epn
# comment line above tells nagios not to use embedded perl interpreter

use strict;
use warnings;

### important to update for every change pushed to production ###
use constant PLUGIN_VERSION => 0.1;
###
use constant PLUGIN_TIMEOUT_SECS => 15;

use Nagios::Plugin;
#use Data::Dumper ('Dumper');

sub get_memcache_data {
    my $np = shift || die("error: no np");
    my $data_ref = shift || die("error: no data_ref");
    my @data = (
    `timeout 5s bash -c 'echo stats | nc localhost 11211 2>/dev/null | egrep "STAT (cas_badval|cmd_flush|cmd_get|curr_connections|evictions|get_hits|get_misses|limit_maxbytes|uptime|pid)"'`,
    `timeout 5s bash -c 'echo "stats slabs" | nc localhost 11211 2>/dev/null | egrep "STAT (total_malloced)"'`
    );
    #    my @data = (`timeout 5s echo stats | nc localhost 11211 2>/dev/null | egrep 'STAT (cas_badval|cmd_flush|cmd_get|curr_connections|evictions|get_hits|get_misses|limit_maxbytes|uptime|pid)'; timeout 5s echo "stats slabs" | nc localhost 11211 2>/dev/null | egrep 'STAT (total_malloced)'`);

    foreach my $line (@data) {
        chomp($line);
        my (undef, $key, $value) = split(/\s+/, $line);
        $data_ref->{'info'}->{$key} = $value;
    }

    my @params = ('cas_badval', 'cmd_flush', 'cmd_get', 'curr_connections', 'evictions', 'get_hits', 'get_misses', 'limit_maxbytes', 'uptime', 'total_malloced', 'pid');

    foreach my $param (@params) {
        if(!defined($data_ref->{'info'}->{$param}) || !length($data_ref->{'info'}->{$param})) {
            $np->nagios_die("$param data is missing");
        }
    }

    $data_ref->{'info'}->{'mem_free_pct'} = sprintf("%0.4f", (($data_ref->{'info'}->{'limit_maxbytes'} - $data_ref->{'info'}->{'total_malloced'}) / $data_ref->{'info'}->{'limit_maxbytes'}) * 100.0);

    if($data_ref->{'info'}->{'cmd_get'}) {
        $data_ref->{'info'}->{'get_hits_pct'} = sprintf("%0.4f", ($data_ref->{'info'}->{'get_hits'} / $data_ref->{'info'}->{'cmd_get'}) * 100.0);
        $data_ref->{'info'}->{'get_misses_pct'} = sprintf("%0.4f", ($data_ref->{'info'}->{'get_misses'} / $data_ref->{'info'}->{'cmd_get'}) * 100.0);
    } else {
        $data_ref->{'info'}->{'get_hits_pct'} = 0;
        $data_ref->{'info'}->{'get_misses_pct'} = 0;
    }

#    print(Dumper($data_ref));
}

sub check_service {
    my $np = shift || die("error: no np");

    my $check_type = $np->opts()->check_type();
    my @param_names = split(/&&&/, $np->opts()->param_name());
    my @warnings = split(/&&&/, $np->opts()->warning());
    my @criticals = split(/&&&/, $np->opts()->critical());

#    print(Dumper(\@param_names));
#    print(Dumper(\@warnings));
#    print(Dumper(\@criticals));

    my $data = {};

    get_memcache_data($np, $data);

    if($check_type eq 'count') {
        my @params = ('cas_badval', 'cmd_flush', 'curr_connections', 'evictions');
        foreach my $param (@params) {
            $data->{'metrics'}->{$param} = $data->{'info'}->{$param};
        }
    } else {
        my @params = ('mem_free_pct', 'get_hits_pct', 'get_misses_pct');
        foreach my $param (@params) {
            $data->{'metrics'}->{$param} = $data->{'info'}->{$param};
        }
    }

    my @errors = ();
    my $status_code = OK;
    my $max_param_names = scalar(@param_names);
    if(scalar(@warnings) != $max_param_names || scalar(@criticals) != $max_param_names) {
        $np->nagios_die("numbers of --param_name, --warning, --critical values do not match");
    }
    for(my $i = 0; $i < $max_param_names; $i++) {
        my $param_name = $param_names[$i];
        my $warning = $warnings[$i];
        my $critical = $criticals[$i];
        if(!defined($data->{'metrics'}->{$param_name})) {
            $np->nagios_die("$param_name data does not exist");
        }

        my $check_threshold_status_code = $np->check_threshold(
            'check' => $data->{'metrics'}->{$param_name},
            'warning' => $warning,
            'critical' => $critical
        );

        if($check_threshold_status_code != OK) {
            push(@errors, sprintf("%s: %s(w=%s c=%s)", $Nagios::Plugin::STATUS_TEXT{$check_threshold_status_code}, $param_name, $warning, $critical));
        }

        if($check_threshold_status_code > $status_code) {
            $status_code = $check_threshold_status_code;
        }
    }

    foreach my $key (sort keys %{$data->{'metrics'}}) {
        $np->add_perfdata(
            'label' => $key,
            'value' => $data->{'metrics'}->{$key},
        );
    }

    my @info = ();
    foreach my $key (sort keys %{$data->{'info'}}) {
        push(@info, sprintf("%s=%s", $key, $data->{'info'}->{$key}));
    }

    my $output = join(' ', @info);
    if(scalar(@errors)) {
        $output .= sprintf(" errors=[%s]", join(', ', @errors));
    }

    $np->nagios_exit($status_code, $output);
}

sub setup_nagios_plugin {
    my $np = Nagios::Plugin->new(
        'shortname' => "memcache-" . PLUGIN_VERSION,
        'usage' => "Usage: %s [ see params below ]",
        'version' => PLUGIN_VERSION,
        'timeout' => PLUGIN_TIMEOUT_SECS
    );

    $np->add_arg(
        'spec' => 'check_type=s',
        'help' => "--check_type=STRING\n\tcheck type\n\tsupported: count, pct",
        'default' => 'pct',
        'required' => 0
    );

    $np->add_arg(
        'spec' => 'param_name=s',
        'help' => "--param_name=STRING\n\tlist of param names for graphing and alerting (delimited by '&&&')\n\t--param_name values are associated with the corresponding values in --warning and --critical\n\tdefault:",
        'default' => '',
        'required' => 0
    );

    $np->add_arg(
        'spec' => 'warning|w=s',
        'help' => "-w, --warning=NUMBER:NUMBER&&&NUMBER:NUMBER\n\tdefault: 0:",
        'default' => '',
        'required' => 0
    );

    $np->add_arg(
        'spec' => 'critical|c=s',
        'help' => "-c, --critical=NUMBER:NUMBER&&&NUMBER:NUMBER\n\tdefault: 0:",
        'default' => '',
        'required' => 0
    );

    $np->add_arg(
        'spec' => 'debug|d',
        'help' => '-d, --debug',
        'default' => 0,
        'required' => 0
    );

    $np->getopts();

    return $np;
}

sub main {
    my $np = setup_nagios_plugin();

#    print(Dumper($np));

    if($np->opts()->debug()) {
        print(STDERR "check_type: " . $np->opts()->check_type() . "\n");
        print(STDERR "param_name: " . $np->opts()->param_name() . "\n");
        print(STDERR "timeout: " . $np->opts()->timeout() . "\n");
        print(STDERR "warning: " . $np->opts()->warning() . "\n");
        print(STDERR "critical: " . $np->opts()->critical() . "\n");
        print(STDERR "verbose: " . $np->opts()->verbose() . "\n");
    }

    check_service($np);
}

main();
