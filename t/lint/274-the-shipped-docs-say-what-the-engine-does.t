#!/usr/bin/perl
# SM1255: THE SHIPPED DOCS SAY WHAT THE ENGINE DOES - the facts a site agent
# found wrong in starter/docs and FEATURES.md (the lazysite.io content check
# against 0.15.16, 2026-10-22, D-1 to D-8), each asked of the CODE here rather
# than of a copy of the right sentence, so the next change to the engine that
# makes one of them false again fails here too.
#
# IT CHECKS FACTS, NOT PROSE, as t/lint/80 does: a number, a key list, a file
# name, a default. Whether a sentence explains them well is not a test's call.
use strict;
use warnings;
use Test::More;
use File::Find ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root load_processor setup_minimal_site site_tempdir);
use Lazysite::Util            ();
use Lazysite::SecurityHeaders ();

my $root = repo_root();

sub slurp {
    my ($rel) = @_;
    open my $fh, '<:utf8', "$root/$rel" or die "$rel: $!";
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

my @SHIPPED;
File::Find::find( { no_chdir => 1,
        wanted => sub { push @SHIPPED, $File::Find::name if /\.md\z/ } }, "$root/starter/docs" );
@SHIPPED = sort map { s{\A\Q$root\E/}{}r } @SHIPPED;
cmp_ok( scalar @SHIPPED, '>', 50, 'the shipped docs were found' );

# --- D-1: view.tt is gone, and nothing links to a page that is not there -------
{
    my @named = grep {
        my $t = slurp($_);
        # The one sentence allowed to name it is the one saying it is gone.
        $t =~ s/^.*\bDo not write `view\.tt`.*$//mg;
        $t =~ /\bview\.tt\b/;
    } @SHIPPED;
    is_deeply( \@named, [], 'no shipped doc names view.tt, which the layouts rework removed' );
    unlike( slurp('lib/Lazysite/Capabilities.pm'), qr/\bview\.tt\b/,
        'and neither does the capability descriptor' );

    my @dead;
    for my $f (@SHIPPED) {
        my $t = slurp($f);
        while ( $t =~ m{\]\((/docs/[A-Za-z0-9_/.-]*?)/?(?:#[^)]*)?\)}g ) {
            my $p = $1;
            ( my $rel = $p ) =~ s{\A/docs}{starter/docs};
            $rel =~ s{\.html\z}{};    # /docs/x.html is the page /docs/x
            next if -f "$root/$rel.md" || -f "$root/$rel/index.md" || -f "$root/$rel";
            push @dead, "$f -> $p";
        }
    }
    is_deeply( \@dead, [], 'every /docs/ link in a shipped doc names a shipped page' )
        or diag( join "\n", @dead );
}

# --- D-2: the per-host keys and the env allowlist are the engine's -------------
{
    my $d = site_tempdir();
    setup_minimal_site($d);
    load_processor($d);
    no warnings 'once';
    my @engine = sort keys %main::ALIAS_OVERRIDE_KEYS;
    cmp_ok( scalar @engine, '>', 9, 'the processor\'s per-host key list was read' );

    my $conf = slurp('starter/docs/configuration.md');
    my ($para) = $conf =~ /Only whitelisted keys may be overridden per host:(.*?)Anything else/s;
    my @doc = ( $para // '' ) =~ /`([a-z0-9_]+)`/g;
    @doc = sort @doc;
    is_deeply( \@doc, \@engine, 'configuration.md lists every key an alias host may override, and no other' );

    my ($env) = $conf =~ /Only these CGI variables may be used with `\$\{VAR\}` syntax:(.*?)\n\n/s;
    my @denv = ( $env // '' ) =~ /`([A-Z_]+)`/g;
    @denv = sort @denv;
    is_deeply( \@denv, [ Lazysite::Util::env_allowlist() ],
        'and every CGI variable lazysite.conf may interpolate' );
}

# --- D-3: the session registry is pruned at the session lifetime ---------------
for my $f (qw(starter/docs/auth.md starter/docs/manager.md)) {
    my $t = slurp($f);
    unlike( $t, qr/self-pruned after 24/, "$f: the registry is not said to prune at a fixed 24 hours" );
    like( $t, qr/`session_lifetime`/, "$f: it names the setting it prunes at" );
}

# --- D-4: the connect code's life is the users tool's ---------------------------
{
    my ($ttl) = slurp('tools/lazysite-users.pl') =~ /^my \$CONNECT_CODE_TTL\s*=\s*([\d_]+);/m;
    ok( defined $ttl, 'the connect code TTL was read from the users tool' );
    ( my $n = $ttl // 0 ) =~ s/_//g;
    my $min = $n / 60;
    my @said = slurp('starter/docs/onboard-ai-agent.md') =~ /connect code has not expired \(it lasts (\d+) minutes/g;
    is_deeply( \@said, [$min], "onboard-ai-agent.md gives the connect code $min minutes, as the code does" );
}

# --- D-5: the CSP ships report-only -----------------------------------------------
{
    my $default = Lazysite::SecurityHeaders::_csp_mode(undef);
    is( $default, 'report-only', 'the CSP mode with nothing set is report-only' );
    like( slurp('starter/docs/reference.md'), qr/`csp`\n: The Content-Security-Policy mode: `\Q$default\E` \(the default/,
        'reference.md gives that default' );
    unlike( slurp('docs/FEATURES.md'), qr/Content-Security-Policy ships enforcing/,
        'FEATURES.md does not say the CSP ships enforcing' );
}

# --- D-7: the block list is on the plugin's own page ----------------------------
unlike( slurp('plugins/bad-url-blocker.pl'), qr/live on the Stats\s*(?:#\s*)?page/,
    'the blocker does not place its block list on the Stats page' );
like( slurp('starter/manager/plugin-config.md'), qr/action=bad-url-blocks/,
    'the plugin config page is where the list is read' );

# --- D-8: page URLs go to the processor, which serves the cache -------------------
# A page's address has no file behind it (/about is about.md, cached as
# about.html), so the shipped front ends hand it on: nginx `try_files $uri
# @lazysite`, Apache's `!-f` conditions and FallbackResource.
unlike( slurp('docs/FEATURES.md'), qr/the web server serves that cache directly/,
    'FEATURES.md does not say the web server serves the page cache' );
like( slurp('installers/nginx/vhost-fcgi.conf.example'), qr/try_files \$uri \@lazysite;/,
    'and the nginx front end does hand an address with no file to the processor' );

# The homepage is the exception, on ONE template: the plain Hestia `lazysite`
# template lists index.html as a DirectoryIndex, so its cache is served
# without the processor. The docs say which template, and this holds the
# set: a template that joins or leaves it makes the docs wrong.
{
    my @serves;
    for my $v ( sort( glob("$root/installers/nginx/*.example"), glob("$root/installers/apache/*.example"),
        glob("$root/installers/hestia/*.tpl"), glob("$root/installers/hestia/*.stpl") ) )
    {
        my $t = do { open my $fh, '<', $v or die $!; local $/; <$fh> };
        my @lists = ( $t =~ /^\s*DirectoryIndex\s+(.*)$/mg, $t =~ /^\s*index\s+([^;]*);/mg );
        push @serves, $v =~ s{\A\Q$root\E/}{}r if grep { /(?:^|\s)index\.html(?:\s|$)/ } @lists;
    }
    is_deeply( \@serves, [ 'installers/hestia/lazysite.stpl', 'installers/hestia/lazysite.tpl' ],
        'only the plain Hestia template serves index.html as a directory index' );
    my $dev = slurp('starter/docs/development.md');
    like( $dev, qr/plain Hestia `lazysite` template \(`lazysite\.tpl` \/ `lazysite\.stpl`\)\s+has `DirectoryIndex index\.html/,
        'development.md names that template as the one that serves the homepage cache' );
    like( $dev, qr/leave `index\.html` out of\s+the index list/, 'and says the others do not' );
    like( slurp('starter/docs/ai-briefing-development.md'), qr/On the plain Hestia `lazysite`\s+template that file is served directly/,
        'and so does the development briefing' );
}

done_testing();
