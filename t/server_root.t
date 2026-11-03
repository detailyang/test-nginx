use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $directory = tempdir(CLEANUP => 1);
my $custom = File::Spec->catfile($directory, 'server root');
for my $randomize (0, 1) {
    for my $prefix (undef, $custom, 't/custom-root') {
        local $ENV{TEST_NGINX_RANDOMIZE} = $randomize;
        local $ENV{TEST_NGINX_SERVROOT};
        if (defined $prefix) {
            $ENV{TEST_NGINX_SERVROOT} = $prefix;
        } else {
            delete $ENV{TEST_NGINX_SERVROOT};
        }

        open my $child, '-|', $^X, '-Ilib', '-MTest::Nginx::Util', '-e',
            '$Test::Nginx::Util::PidFile = undef; '
            . 'print "$Test::Nginx::Util::ServRoot\n$Test::Nginx::Util::ServerPort\n";'
            or die "cannot start root probe: $!";
        my $root = <$child>;
        my $port = <$child>;
        chomp($root, $port);
        close $child;
        is($?, 0, 'root probe exited successfully');
        my $expected = defined $prefix ? $prefix : 't/servroot';
        $expected .= "_" . $port if $randomize;
        $expected = File::Spec->rel2abs($expected) if $randomize || !defined $prefix;
        is($root, $expected,
           'configured root and random port agree');
    }
}

for my $status (0, 7) {
    local $ENV{TEST_NGINX_RANDOMIZE} = 1;
    local $ENV{TEST_NGINX_SERVROOT} = File::Spec->catfile($directory, 'server root;$literal');
    open my $child, '-|', $^X, '-Ilib', '-MTest::Nginx::Util', '-e',
        'use File::Path qw(make_path); '
        . '$Test::Nginx::Util::PidFile = undef; '
        . 'make_path($Test::Nginx::Util::ServRoot); '
        . 'print $Test::Nginx::Util::ServRoot; exit $ARGV[0];', $status
        or die "cannot start cleanup probe: $!";
    local $/;
    my $root = <$child>;
    close $child;
    is($? >> 8, $status, 'randomized cleanup preserves the exit status');
    ok(!-e $root, 'custom randomized root is removed literally');
    ok(-d $directory, 'cleanup preserves the root parent');
}

done_testing();
