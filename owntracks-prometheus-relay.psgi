#!perl

use v5.24;
use strict;
use warnings;
use MIME::Base64 qw(encode_base64);
use Math::Trig qw(great_circle_distance great_circle_waypoint deg2rad rad2deg);
use POSIX qw(ceil floor);

BEGIN {
	# JSON::PP comes preinstalled with base perl package,
	# while JSON::XS is optional so it might be missing.
	my @json_req = qw(decode_json encode_json);
	eval {
		require JSON::XS;
		JSON::XS->import( @json_req );
		1;
	} or do {
		require JSON::PP;
		JSON::PP->import( @json_req );
	}
}

use constant {
	INTERPOLATION_TIME_MAX => 60000,
	PROMETHEUS_PREFIX => "owntracks",
};

use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Indent = 1;
$Data::Dumper::Useqq = 1;

use constant p => !$ENV{DEBUG};
sub t
{
	my ( $fmt, @args ) = @_;
	chomp $fmt;
	$fmt .= "\n";
	my @pargs = map { ref $_ ?
		Dumper( $_ )
			=~ s/\A\$VAR.*?=\s*//r
			=~ s/;\n\z//sr
		: $_ } @args;
	printf STDERR $fmt, @pargs;
}

my %cards;
foreach my $fn ( glob "*.png" )
{
	open my $fin, '<', $fn
		or die "Cannot open $fn: $!";

	local $/ = undef;
	my $data = <$fin>;
	close $fin;

	$fn =~ s/\.png$//;
	my ( $tid, $name ) = split /\s*:\s*/, $fn, 2;
	$cards{ $tid } = {
		_type => "card",
		tid => $tid,
		name => $name,
		face => encode_base64( $data, '' ),
	};
}

my %last_recorded;

my %report;
my %distance;
my %stats;

sub record_location_point
{
	my ( $payload ) = @_;

	my $tid = $payload->{tid};
	my $time = $payload->{tst};

	my $report = $report{ $tid, $time } //= {};

	$report->{ "location", "coordinate" } = {
		latitude => $payload->{lat},
		longitude => $payload->{lon},
	};
	$report->{ "altitude" } = $payload->{alt};
	$report->{ "distance" } = $payload->{distance};

	p or t "Reporting %s point at %d: %s", $tid, $time, $report;
}

sub record_location_only
{
	my ( $first, $last ) = @_;

	unless ( $first )
	{
		$last->{distance} //= 0;
		return record_location_point( $last );
	}

	my $time_diff = $last->{tst} - $first->{tst};
	return unless $time_diff > 0;

	my $distance_diff = great_circle_distance(
		deg2rad( $first->{lon} ), deg2rad( 90 - $first->{lat} ),
		deg2rad( $last->{lon} ), deg2rad( 90 - $last->{lat} ),
	6378 ) // 0;

	# FIXME: The GPS coordinates will randomly fluctuate even when not
	# moving. This will accumulate as distance travelled. We want to filter
	# it out, but we do not want to accidentally remove slow moving speeds.
	# $distance_diff = 0 unless $distance_diff > 0.04;

	$last->{distance} = $first->{distance} + $distance_diff;

	my $points = POSIX::ceil( $time_diff / INTERPOLATION_TIME_MAX );

	my $alt_diff = $last->{alt} - $first->{alt};
	my $time_diff_per_point = POSIX::ceil( $time_diff / $points );
	my $alt_diff_per_point = $alt_diff / $points;
	my $distance_diff_per_point = $distance_diff / $points;
	my $previous = $first;
	for ( my $i = 1; $i < $points; $i++ )
	{
		my $way = $i / $points;
		my ( $lon_rad, $lat_rad ) = great_circle_waypoint(
			deg2rad( $first->{lon} ), deg2rad( 90 - $first->{lat} ),
			deg2rad( $last->{lon} ), deg2rad( 90 - $last->{lat} ),
			$way,
		);
		my $this = {
			tid => $last->{tid},
			tst => $previous->{tst} + $time_diff_per_point,
			lat => 90 - rad2deg( $lat_rad ),
			lon => rad2deg( $lon_rad ),
			alt => $previous->{alt} + $alt_diff_per_point,
			distance => $previous->{distance} + $distance_diff_per_point,
		};
		record_location_point( $this );
		$previous = $this;
	}
	record_location_point( $last );
}

sub record_status_point
{
	my ( $payload ) = @_;

	my $tid = $payload->{tid};
	my $time = $payload->{created_at};

	my $report = $report{ $tid, $time } //= {};

	$report->{battery_charge} = $payload->{batt};
}

sub record_status_only
{
	my ( $first, $last ) = @_;

	return unless defined $last->{batt};
	record_status_point( $last );
	return unless $first;

	my $time_diff = $last->{created_at} - $first->{created_at};
	return unless $time_diff > 0;

	my $points = POSIX::ceil( $time_diff / INTERPOLATION_TIME_MAX );
	p or t "Splitting %d ms into %d points", $time_diff, $points;

	my $time_diff_per_point = POSIX::ceil( $time_diff / $points );

	my $batt_diff = $last->{batt} - $first->{batt};
	my $batt_diff_per_point = $batt_diff / $points;

	my $previous = $first;
	for ( my $i = 1; $i < $points; $i++ )
	{
		my $this = {
			tid => $last->{tid},
			created_at => $previous->{created_at} + $time_diff_per_point,
			batt => $previous->{batt} + $batt_diff_per_point,
		};
		record_status_point( $this );
		$previous = $this;
	}
}

sub record_location
{
	my ( $user, $device, $payload ) = @_;

	my $tid = $payload->{tid};
	my $previous = $last_recorded{ $tid };
	$payload->{tst} *= 1000;
	$payload->{created_at} *= 1000;

	record_location_only( $previous, $payload );
	record_status_only( $previous, $payload );

=for later
	# battery charge: linear interpolation
	# battery status: NaN unless constant
	# network type: NaN unless constant
	{
		# Battery status (unplugged, charging)
		my $bs = $payload->{bs};
		if ( defined $bs )
		{
			my @names = qw(unknown unplugged charging full);
			my $out = $report{ "battery_status", $tid, $time, "status" } = {
				$names[ $bs ] => 1,
			};
			my $pbs = $previous->{bs} // 0;
			$out->{ $names[ $pbs ] } = "NaN"
				if $pbs != $bs;
		}

		# Network connection type
		if ( my $ct = $payload->{conn} )
		{
			my %names = ( o => "offline", m => "mobile", w => "wifi", "" => "unknown" );
			my $out = $report{ "network_connection", $tid, $time, "type" } = {
				($names{ $ct } // $names{""}) => 1,
			};
			my $pct = $previous->{conn} // "";
			$out->{ $names{ $pct } } = "NaN"
				if $pct ne $ct;
		}
	}
=cut
	$payload->{distance} //= 0;
	$last_recorded{ $tid } = $payload;
	return;
}

sub make_friends
{
	my ( $tid ) = @_;
	my @ret;

	{
		# Resend cards at most once every 24 hours, to save bandwidth
		state %seen_card;
		my $now = time;
		foreach my $key ( sort keys %cards )
		{
			next unless $now >= ( $seen_card{ $tid, $key } // 0 );
			push @ret, $cards{ $key }
				unless $key eq $tid;
			$seen_card{ $tid, $key } = $now + 24 * 3600;
		}
	}

	my @copy_keys = qw(_type tid lat lon tst acc batt alt vel);
	foreach my $key ( sort keys %last_recorded )
	{
		next if $key eq $tid;
		my $src = $last_recorded{ $key };
		my %location;
		@location{ @copy_keys } = @$src{ @copy_keys };
		$location{tst} = $src->{tst} / 1000;
		push @ret, \%location;
	}
	return \@ret;
}

sub _owntracks
{
	my ( $env ) = @_;

	# We only expect post
	return unless $env->{REQUEST_METHOD} eq "POST";

	# Sometimes the POST has zero-length. No idea what that means.
	my $content_length = $env->{CONTENT_LENGTH} // 0;
	return unless $content_length > 0;

	$env->{'psgi.input'}->read( my $post, $content_length );
	p or t "# POST: %s", $post;
	my $payload = decode_json( $post );

	my $tid = $payload->{tid} // "unknown";
	my $type = $payload->{_type} // "unknown";
	$stats{ "requests", qq(tid="$tid",type="$type") }++;

	my $user = $env->{HTTP_X_LIMIT_U};
	my $device = $env->{HTTP_X_LIMIT_D};

	if ( $payload->{_type} eq "location" )
	{
		record_location( $user, $device, $payload );
		return make_friends( $payload->{tid} );
	}

	return;
}
sub owntracks
{
	# Always return a reasonable json, otherwise the app might crash.
	my $ret = _owntracks( @_ );
	my $json = encode_json( $ret // [] );
	p or t "# Response: %s", $json;
	return [
		'200',
		[ 'Content-Type' => 'application/json' ],
		[ $json ],
	];
}

my %help = (
	location => 'GPS data of the device',
	altitude => 'Meters above sea level',
	distance => 'Distance travelled by the device',
	battery_charge => 'Device battery charge percentage',
	requests => 'Number of http requests from device',
);
my %help_type = (
	# Default is "gauge"
	distance => "counter"
);
sub prometheus
{
	my ( $env ) = @_;

	my %ret;
	p or t "Dumping report: %s", \%report;
	foreach my $group_key ( sort keys %report )
	{
		my ( $tid, $time ) = split $;, $group_key;
		my $group = $report{ $group_key };

		foreach my $metric_key ( sort keys %$group )
		{
			my ( $metric, $tag ) = split $;, $metric_key;
			my $ret = $ret{ $metric } //= [];

			my $fullname = join "_", PROMETHEUS_PREFIX, $metric;
			unless ( @$ret )
			{
				my $help = $help{ $metric } // "$metric from owntracks";
				my $type = $help_type{ $metric } // "gauge";
				push @$ret,
					"# HELP $fullname $help",
					"# TYPE $fullname $type";
			}

			my $value = $group->{ $metric_key };
			if ( length $tag )
			{
				foreach my $subkey ( sort keys %$value )
				{
					my $subvalue = $value->{ $subkey };
					push @$ret, sprintf '%s{tid="%s",%s="%s"} %s %d',
						$fullname, $tid, $tag, $subkey, $subvalue, $time;
				}
			}
			else
			{
				push @$ret, sprintf '%s{tid="%s"} %s %d',
					$fullname, $tid, $value, $time;
			}
		}
	}
	foreach my $key ( sort keys %stats )
	{
		my ( $metric, $tags ) = split $;, $key;
		my $ret = $ret{ $metric } //= [];

		my $fullname = join "_", PROMETHEUS_PREFIX, $metric;
		unless ( @$ret )
		{
			my $help = $help{ $metric } // "$metric from owntracks";
			push @$ret,
				"# HELP $fullname $help",
				"# TYPE $fullname counter";
		}
		push @$ret, sprintf "%s{%s} %s",
			$fullname, $tags, $stats{ $key };
	}

	%report = ();
	return [
		200,
		[ 'Content-Type' => 'text/plain' ],
		[ join "\n", map @$_, values %ret ],
	];
}

my $app = sub
{
	my ( $env ) = @_;
	my $path = $env->{PATH_INFO};

	if ( $path =~ m#/pub\z# )
	{
		return owntracks( $env );
	}
	elsif ( $path =~ m#/metrics\z# )
	{
		return prometheus( $env );
	}
	return [ 404, [], [] ];
};

$app;
