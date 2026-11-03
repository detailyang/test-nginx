use strict;
use warnings;

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Open2 qw(open2);
use Storable qw(thaw);
use Test::More;

my $library = abs_path('lib');
my $directory = tempdir(CLEANUP => 1);
my $shared = File::Spec->catdir($directory, 't', 'tmp');
make_path($shared);
my $sentinel = File::Spec->catfile($shared, 'unrelated.txt');
open my $fixture, '>', $sentinel or die "cannot create $sentinel: $!";
print {$fixture} 'unrelated request data';
close $fixture;

my $probe = <<'PERL';
use strict;
use warnings;
no warnings 'once';
use File::Spec;
use Storable qw(nfreeze);

my ($directory, $protocol) = @ARGV;
chdir $directory or die "cannot chdir to $directory: $!";
my $module = $protocol eq 'stream' ? 'Stream' : 'Dgram';
require "Test/Nginx/Socket/Lua/$module.pm";

my $preprocess = $Test::Nginx::Util::BlockPreprocessors[0];
my @requests = ("binary\0\xff\r\n>>> literal\n", '', "third request\r\n");
my @results;
for my $iteration (1, 2) {
    my $block = Test::Base::Block->new;
    $block->set_value('name', "$protocol request files $iteration");
    $block->set_value('post_setup_server_root',
        '$Test::Nginx::Util::RequestFileHookCount++;');
    $block->set_value('user_files', ">>> fixture.txt\nexisting fixture\n");

    for my $index (0 .. 2) {
        my $suffix = $index ? $index + 1 : '';
        $block->set_value("${protocol}_server_config$suffix", '');
        $block->set_value("${protocol}_request$suffix", $requests[$index]);
    }

    $preprocess->($block);
    my @paths = $block->config =~ /io\.open\('([^']+)', 'r'\)/g;
    my @before = map { -e $_ ? 1 : 0 } @paths;

    Test::Nginx::Util::setup_server_root($iteration == 1);
    Test::Nginx::Util::run_customer_init_script($block);
    Test::Nginx::Util::write_user_files($block, {});

    my @contents;
    for my $path (@paths) {
        open my $file, '<', $path or die "cannot open $path: $!";
        binmode $file;
        local $/;
        push @contents, unpack('H*', <$file>);
        close $file;
    }

    push @results, {
        paths => \@paths,
        before => \@before,
        contents => \@contents,
        hook_count => $Test::Nginx::Util::RequestFileHookCount,
        fixture_exists => -f File::Spec->catfile(
            $Test::Nginx::Util::HtmlDir, 'fixture.txt') ? 1 : 0,
    };
}

my @old_files = map { -e $_ ? 1 : 0 } @{$results[0]->{paths}};
$| = 1;
print unpack('H*', nfreeze({
    root => $Test::Nginx::Util::ServRoot,
    html => $Test::Nginx::Util::HtmlDir,
    results => \@results,
    old_files => \@old_files,
})), "\n";
<STDIN>;
PERL

my @children;
END {
    local $?;
    for my $child (@children) {
        next if !$child->{pid};
        kill 'TERM', $child->{pid};
        waitpid $child->{pid}, 0;
    }
}

local $ENV{TEST_NGINX_RANDOMIZE} = 1;
local $ENV{TEST_NGINX_SERVROOT};
delete $ENV{TEST_NGINX_SERVROOT};
local $ENV{TEST_NGINX_NO_CLEAN};
delete $ENV{TEST_NGINX_NO_CLEAN};
local $ENV{TEST_NGINX_USE_HUP};
delete $ENV{TEST_NGINX_USE_HUP};

for my $protocol ('stream', 'dgram') {
    my ($reader, $writer);
    my $pid = open2($reader, $writer, $^X, "-I$library", '-e',
                    $probe, $directory, $protocol);
    my $child = { pid => $pid, reader => $reader, writer => $writer };
    push @children, $child;
    my $line = <$reader>;
    BAIL_OUT("$protocol request-file probe did not produce a result")
        if !defined $line;
    chomp $line;
    $child->{result} = thaw(pack('H*', $line));

    my $result = $child->{result};
    for my $iteration (0, 1) {
        my $files = $result->{results}->[$iteration];
        is(scalar @{$files->{paths}}, 3,
           "$protocol generates request, request2 and request3 files");
        for my $path (@{$files->{paths}}) {
            is(dirname($path), $result->{html},
               "$protocol uses its own html directory");
        }
        is_deeply($files->{before}, [0, 0, 0],
                  "$protocol defers file creation until server-root setup");
        is_deeply($files->{contents},
                  [map { unpack('H*', $_) }
                   ("binary\0\xff\r\n>>> literal\n", '', "third request\r\n")],
                  "$protocol preserves binary and empty request data");
        is($files->{hook_count}, $iteration + 1,
           "$protocol preserves the existing server-root hook");
        ok($files->{fixture_exists}, "$protocol preserves user_files");
    }
    is_deeply($result->{old_files}, [0, 0, 0],
              "$protocol removes previous request files on server-root reset");
}

isnt($children[0]->{result}->{root}, $children[1]->{result}->{root},
     'concurrent processes use different server roots');

for my $index (0, 1) {
    my $child = $children[$index];
    print {$child->{writer}} "finish\n";
    close $child->{writer};
    close $child->{reader};
    waitpid $child->{pid}, 0;
    $child->{pid} = undef;
    is($?, 0, 'request-file process exits successfully');
    ok(!-d $child->{result}->{root}, 'normal cleanup removes its server root');
    ok(-f $sentinel, 'cleanup preserves unrelated shared temporary files');
    if ($index == 0) {
        for my $path (@{$children[1]->{result}->{results}->[1]->{paths}}) {
            ok(-f $path, 'cleanup preserves the other process request files');
        }
    }
}

done_testing();
