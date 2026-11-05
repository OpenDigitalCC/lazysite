#!/usr/bin/perl
# SM1328 (ruling 52, T-13): THE PAGES NAME ODOO BY odoo_display_name. /odoo-signin's
# text and its button, /login's link to it, and the script tag the processor adds
# for the browser helper (which carries the name the helper's dialog says) - with the
# setting absent ("Odoo", as before), a name, and an empty value (no name, and each
# text reads whole). A name is text, escaped where it lands. The errors and the
# helper's own texts are t/unit/odoo/121.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root run_processor site_tempdir);

my $root = repo_root();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub site {
    my ($name) = @_;
    my $d = site_tempdir();
    system( 'cp', '-r', "$root/starter/.", $d ) == 0 or die 'copy starter';
    make_path("$d/lazysite/cache");
    spit( "$d/lazysite/lazysite.conf", "site_name: Probe\nplugins:\n  - plugins/odoo.pl\n" );
    spit( "$d/lazysite/odoo.conf", "odoo_site_signin: on\n" . ( defined $name ? "odoo_display_name: $name\n" : '' ) );
    return $d;
}
sub pages {
    my ($d) = @_;
    my $signin = run_processor( $d, '/odoo-signin' );
    my $login  = run_processor( $d, '/login' );
    my ($button) = $signin =~ m{<button type="button" data-ls-odoo-signin data-ls-odoo-next>(.*?)</button>}s;
    my ($tag)    = $signin =~ m{(<script src="/assets/lazysite-odoo\.js[^>]*>)};
    my ($link)   = $login =~ m{<p class="login-odoo" data-ls-auth-in><a href="/odoo-signin">(.*?)</a></p>}s;
    return { page => $signin, button => $button, tag => $tag, link => $link };
}

subtest 'absent: Odoo, as before' => sub {
    my $p = pages( site(undef) );
    is( $p->{button}, 'Sign in with your Odoo login', 'the button' );
    like( $p->{page}, qr/This site's sign-in is your Odoo login: the user name and\s+password you use for Odoo/, 'the page text' );
    like( $p->{page}, qr/Signing out here signs you out of Odoo too\./, '...to its end' );
    is( $p->{link}, 'Sign in with Odoo', '/login\'s link' );
    like( $p->{tag} // '', qr/ data-ls-odoo-display-name="Odoo" /, 'the helper is told Odoo' );
};

subtest 'a name' => sub {
    my $p = pages( site('Acme Office') );
    is( $p->{button}, 'Sign in with your Acme Office login', 'the button' );
    like( $p->{page}, qr/This site's sign-in is your Acme Office login: the user name and\s+password you use for Acme Office/,
        'the page text' );
    unlike( $p->{page} =~ s{<script\b.*?</script>}{}gsr, qr/sign-in is your Odoo|you use for Odoo|out of Odoo/, 'and no Odoo in it' );
    is( $p->{link}, 'Sign in with Acme Office', '/login\'s link' );
    like( $p->{tag} // '', qr/ data-ls-odoo-display-name="Acme Office" /, 'the helper is told the name' );
};

subtest 'empty: no name, and the texts read whole' => sub {
    my $p = pages( site('') );
    is( $p->{button}, 'Sign in', 'the button' );
    like( $p->{page}, qr/Sign in with your user name and password, and the code from your authenticator app\s+if you are asked for one\. Signing out here ends that sign-in too\./,
        'the page text' );
    unlike( $p->{page}, qr/sign-in is your\s+login|you use for\s*,|out of\s+too/, 'with no hole where a name was' );
    is( $p->{link}, 'Sign in another way', '/login\'s link' );
    like( $p->{tag} // '', qr/ data-ls-odoo-display-name="" /, 'the helper is told there is none' );
};

subtest 'a name is text where it lands' => sub {
    my $p = pages( site(q{A&B <i>"x"</i>}) );
    is( $p->{button}, 'Sign in with your A&amp;B &lt;i&gt;&quot;x&quot;&lt;/i&gt; login', 'escaped in the button' );
    is( $p->{link}, 'Sign in with A&amp;B &lt;i&gt;&quot;x&quot;&lt;/i&gt;', 'in the link' );
    like( $p->{tag} // '', qr/ data-ls-odoo-display-name="A&amp;B &lt;i&gt;&quot;x&quot;&lt;\/i&gt;" /, 'and in the attribute' );
    unlike( $p->{page}, qr/<i>"x"<\/i>/, 'never as markup' );
};

done_testing;
