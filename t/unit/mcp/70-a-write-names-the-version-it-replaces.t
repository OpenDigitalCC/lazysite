#!/usr/bin/perl
# SM1327 (ruling 51 (b), T-06): write_file takes an optional base_mtime, the mtime
# read_file returned. Given and still the file's, the write is made; given and
# stale (another writer saved since), nothing is written and the answer is a
# conflict naming the current mtime; absent, the write is what it always was.
# write_file passed undef to action_save, which skips the conflict check, so an
# agent writing back a file it had read replaced another writer's save.
#
# The two read-modify-writes inside other tools (rename_page's alias and the link
# rewrite) save with the time they read, as replace_text does (SM1310): the
# second writer is put between the read and the save by a wrapper around
# Files::action_save, as t/unit/mcp/67 puts it after action_read.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir run_child);

my $root = "$FindBin::Bin/../../..";
my $d    = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/content" );
sub put {
    my ( $rel, $text ) = @_;
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
sub slurp { open my $f, '<', "$d/$_[0]" or return ''; local $/; my $c = <$f>; close $f; return $c }
put( 'lazysite/lazysite.conf', "site_name: T\nmcp_enabled: true\n" );
put( 'lazysite/auth/users',    "agent:x\n" );

my $stub = "$d/users-stub.pl";
put( 'users-stub.pl', <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1 } });
STUB
chmod 0755, $stub;

# The second writer, landed on T_SECOND_WRITER's page just before the first save
# to it, a few seconds later by the clock (utime) - as a save that finished in
# between leaves it.
my $wrap = "$d/mcp-with-a-second-writer.pl";
put( 'mcp-with-a-second-writer.pl', <<"WRAP" );
use strict; use warnings;
use lib '$root/lib';
require Lazysite::Manager::Files;
my \$orig = \\&Lazysite::Manager::Files::action_save;
my \$done = 0;
{
    no warnings 'redefine';
    *Lazysite::Manager::Files::action_save = sub {
        my ( \$path ) = \@_;
        my \$want = \$ENV{T_SECOND_WRITER} // '';
        ( my \$p = \$path // '' ) =~ s{^/+}{};
        if ( length \$want && \$p eq \$want && !\$done++ ) {
            my \$f = \$ENV{DOCUMENT_ROOT} . '/' . \$want;
            my \$m = ( stat \$f )[9];
            open my \$fh, '>>', \$f or die \$!;
            print {\$fh} "OTHER WRITER'S LINE\\n";
            close \$fh;
            utime( \$m + 5, \$m + 5, \$f );
        }
        return \$orig->(\@_);
    };
}
do '$root/lazysite-mcp.pl';
die \$@ if \$@;
WRAP

sub call {
    my ( $tool, $args, $second ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer agent:lzs_tok';
    $ENV{T_SECOND_WRITER}     = $second // '';
    my $resp = run_child( [ $^X, $wrap ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
    return $j && $j->{result} ? $j->{result}{structuredContent} : $j;
}

sub fresh_page {
    put( 'content/page.md', "---\ntitle: P\n---\nFirst line.\n" );
    utime( time - 60, time - 60, "$d/content/page.md" );
}

subtest 'read_file and read_page answer the time to pass' => sub {
    fresh_page();
    my $m = ( stat "$d/content/page.md" )[9];
    my $rf = call( 'read_file', { path => '/content/page.md' } );
    is( $rf->{mtime}, $m, 'read_file: mtime' ) or diag explain $rf;
    my $rp = call( 'read_page', { path => '/content/page.md' } );
    is( $rp->{modified}, $m, 'read_page: modified' ) or diag explain $rp;
};

subtest 'a base that is still the file\'s: the write is made' => sub {
    fresh_page();
    my $base = call( 'read_file', { path => '/content/page.md' } )->{mtime};
    my $r = call( 'write_file', { path => '/content/page.md', content => "---\ntitle: P\n---\nMine.\n", base_mtime => $base } );
    ok( $r && $r->{ok}, 'saved' ) or diag explain $r;
    like( slurp('content/page.md'), qr/Mine\./, 'and the file carries it' );
};

subtest 'a stale base: refused, and the file is unchanged' => sub {
    fresh_page();
    my $base = call( 'read_file', { path => '/content/page.md' } )->{mtime};
    # another writer saves after the read
    put( 'content/page.md', "---\ntitle: P\n---\nTheirs.\n" );
    utime( $base + 5, $base + 5, "$d/content/page.md" );
    my $before = slurp('content/page.md');
    my $r = call( 'write_file', { path => '/content/page.md', content => "---\ntitle: P\n---\nMine.\n", base_mtime => $base } );
    ok( $r && !$r->{ok}, 'refused' ) or diag explain $r;
    ok( $r->{conflict}, 'as a conflict' );
    is( $r->{kind} // '', 'conflict', 'of kind conflict' );
    is( $r->{mtime}, $base + 5, 'naming the current mtime' );
    like( $r->{error} // '', qr/mtime is now \Q@{[ $base + 5 ]}\E.*nothing was written/s, 'in its sentence too' );
    is( slurp('content/page.md'), $before, 'the file is unchanged' );

    my $again = call( 'write_file', { path => '/content/page.md', content => "---\ntitle: P\n---\nMine.\n", base_mtime => $r->{mtime} } );
    ok( $again && $again->{ok}, 'with the mtime the conflict named, the write is made' ) or diag explain $again;
};

subtest 'a base for a file that is gone: refused, nothing created' => sub {
    my $r = call( 'write_file', { path => '/content/gone.md', content => "---\ntitle: G\n---\n", base_mtime => time - 100 } );
    ok( $r && !$r->{ok} && $r->{conflict}, 'refused as a conflict' ) or diag explain $r;
    ok( !-e "$d/content/gone.md", 'and no file was made' );
};

subtest 'a base that is not a time is refused by name' => sub {
    fresh_page();
    my $before = slurp('content/page.md');
    my $r = call( 'write_file', { path => '/content/page.md', content => 'x', base_mtime => 'yesterday' } );
    ok( $r && !$r->{ok}, 'refused' ) or diag explain $r;
    is( $r->{field} // '', 'base_mtime', 'naming base_mtime' );
    is( slurp('content/page.md'), $before, 'nothing written' );
};

subtest 'no base: the write is made whatever the file holds (as before)' => sub {
    fresh_page();
    put( 'content/page.md', "---\ntitle: P\n---\nTheirs.\n" );
    my $r = call( 'write_file', { path => '/content/page.md', content => "---\ntitle: P\n---\nMine.\n" } );
    ok( $r && $r->{ok}, 'saved' ) or diag explain $r;
    is( slurp('content/page.md'), "---\ntitle: P\n---\nMine.\n", 'replacing what was there' );
};

subtest 'the schema offers base_mtime and does not require it' => sub {
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/list' } );
    local %ENV = %ENV;
    @ENV{qw(DOCUMENT_ROOT REQUEST_METHOD CONTENT_LENGTH LAZYSITE_USERS_TOOL HTTP_AUTHORIZATION)}
        = ( $d, 'POST', length $body, $stub, 'Bearer agent:lzs_tok' );
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my ($wf) = grep { $_->{name} eq 'write_file' } @{ ( eval { decode_json($jb) } || {} )->{result}{tools} || [] };
    ok( $wf && $wf->{inputSchema}{properties}{base_mtime}, 'write_file has base_mtime' );
    ok( $wf && !grep( { $_ eq 'base_mtime' } @{ $wf->{inputSchema}{required} } ), 'optional' );
    like( $wf ? $wf->{description} : '', qr/base_mtime/, 'and its description says how to use it' );
};

subtest 'rename_page\'s alias is not written over a save made since its read' => sub {
    put( 'content/old.md', "---\ntitle: O\n---\nBody.\n" );
    unlink "$d/content/new.md";
    utime( time - 60, time - 60, "$d/content/old.md" );
    my $r = call( 'rename_page', { old => 'content/old', new => 'content/new', add_alias => 1 }, 'content/new.md' );
    ok( $r && $r->{ok}, 'the rename itself is made' ) or diag explain $r;
    ok( $r && !$r->{alias_added}, 'the alias is not added' ) or diag explain $r;
    like( slurp('content/new.md'), qr/OTHER WRITER'S LINE/, 'and the other writer\'s change is kept' );
};

subtest 'a link rewrite is not written over a save made since its read' => sub {
    put( 'content/a.md', "---\ntitle: A\n---\nBody.\n" );
    put( 'content/links.md', "---\ntitle: L\n---\nSee [A](/content/a).\n" );
    utime( time - 60, time - 60, "$d/content/links.md" );
    unlink "$d/content/b.md";
    my $r = call( 'rename_page', { old => 'content/a', new => 'content/b', update_links => 1 }, 'content/links.md' );
    ok( $r && $r->{ok}, 'the rename itself is made' ) or diag explain $r;
    my $links = slurp('content/links.md');
    like( $links, qr/OTHER WRITER'S LINE/, 'the other writer\'s change is kept' );
    is( $r->{links_updated} // 0, 0, 'and the page is not counted as rewritten' );
};

done_testing;
