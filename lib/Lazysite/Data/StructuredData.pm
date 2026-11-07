package Lazysite::Data::StructuredData;

# SM1357: STRUCTURED DATA FOR SEARCH - schema.org JSON-LD built from a site's
# own tables and schedules.
#
# THE MAPPING IS IN THE TABLE'S DESCRIPTOR, under `structured_data:` - chosen
# over a separate mapping file (the filing says why): it is saved through the
# descriptor door every table already has (save_data_table / data-table-save),
# refused there by name when it is wrong, read back as written, and it travels
# with its table in a backup or a site package. An app ships the mapping for its
# market with its tables; the engine ships none.
#
#   structured_data:
#     type: Event                 a schema.org type
#     pages: [/events]            the pages that carry it
#     properties:
#       name: title               property: a field of the table
#       startDate: starts
#       eventStatus: "=https://schema.org/EventScheduled"   =text is literal
#       location:                 a nested object
#         type: Place
#         properties:
#           name: venue
#
# On a `schedule: true` table the mapping describes ONE thing - the place the
# schedule is the opening hours of - so its properties are literal and the
# engine adds openingHoursSpecification from the schedule.
#
# WHAT IS PUBLISHED IS WHAT THE SITE ALREADY SERVES PUBLICLY. The rows are read
# through Tables::resolve_binding as an anonymous visitor, so a table that is
# not public emits nothing, a `where:` row condition and `shows_from` /
# `shows_until` apply, and no protected value can reach a page's JSON-LD that
# the data endpoint would not hand the same visitor.
#
# INERT BY CONSTRUCTION. Every value goes through one encoder (encode_inert):
# JSON, ASCII-only, with < > & written as < > &, so no row value
# can close the <script> element it sits in, open a comment or begin markup.

use strict;
use warnings;
use JSON::PP        ();
use Lazysite::Util  ();
use Lazysite::Paths ();

my $TYPE = qr/\A[A-Z][A-Za-z0-9]{1,63}\z/;
my $PROP = qr/\A[a-z][A-Za-z0-9]{0,63}\z/;
my $PAGE = qr{\A/(?:[A-Za-z0-9._~-]+/?)*\z};

our $MAX_ROWS  = 100;    # objects one mapping emits on a page
our $MAX_DEPTH = 3;      # nesting of objects inside a mapping

# Properties whose value is a link: a value with a scheme that is not a web or
# mail address is dropped rather than published (the same rule as | url_safe).
my %LINK_PROP = map { $_ => 1 } qw(url sameAs image logo photo thumbnailUrl contentUrl);

# The types lazysite check knows the essentials of. A type outside this list is
# emitted as mapped and named as unchecked, never refused: schema.org has
# hundreds and the engine has no business choosing among them.
my %REQUIRED = (
    Organization              => [qw(name)],
    LocalBusiness             => [qw(name)],
    Restaurant                => [qw(name)],
    Store                     => [qw(name)],
    Place                     => [qw(name)],
    Person                    => [qw(name)],
    Product                   => [qw(name)],
    Offer                     => [qw(price priceCurrency)],
    Service                   => [qw(name)],
    MenuItem                  => [qw(name)],
    Event                     => [qw(name startDate)],
    Article                   => [qw(headline)],
    BlogPosting               => [qw(headline)],
    JobPosting                => [qw(title datePosted)],
    Course                    => [qw(name)],
    PostalAddress             => [],
    OpeningHoursSpecification => [qw(opens closes)],
);
my %DATE_PROP = map { $_ => 1 } qw(startDate endDate datePosted validFrom validThrough
    datePublished dateModified dateCreated birthDate);

sub known_type { return exists $REQUIRED{ $_[0] // '' } ? 1 : 0 }

# --- the mapping, checked at descriptor load -------------------------------------

# ( \%mapping, undef ) or ( undef, 'reason' ). $fields is the descriptor's field
# map, $key its key, $owned a sub answering whether a column is the engine's
# (created_at and friends), $schedule whether this is a schedule table.
sub check_mapping {
    my ( $raw, $fields, $key, $owned, $schedule ) = @_;
    return ( undef, 'structured_data must be a mapping (type, pages, properties)' )
        unless ref $raw eq 'HASH';
    for my $k ( sort keys %$raw ) {
        return ( undef, "structured_data: '$k' is not one of type, pages, properties" )
            unless $k =~ /\A(?:type|pages|properties)\z/;
    }
    my $pages = $raw->{pages};
    $pages = [$pages] if defined $pages && !ref $pages;
    return ( undef, 'structured_data: pages must name at least one page, as a list of site paths' )
        unless ref $pages eq 'ARRAY' && @$pages;
    return ( undef, 'structured_data: pages names more than 50 pages' ) if @$pages > 50;
    for my $p (@$pages) {
        return ( undef, "structured_data: page '" . ( $p // '' ) . "' is not a site path such as /events" )
            unless defined $p && !ref $p && $p =~ $PAGE && $p !~ m{(?:\A|/)\.\.?(?:/|\z)};
    }
    my ( $obj, $why ) = _check_object( $raw, $fields, $key, $owned, $schedule, 1 );
    return ( undef, $why ) if $why;
    my @norm = map { my $x = $_; $x =~ s{(?<=.)/\z}{}; $x } @$pages;
    return ( { %$obj, pages => \@norm, ( $schedule ? ( schedule => 1 ) : () ) }, undef );
}

sub _check_object {
    my ( $raw, $fields, $key, $owned, $schedule, $depth ) = @_;
    my $type = $raw->{type};
    return ( undef, 'structured_data: type is required, a schema.org type such as Event' )
        unless defined $type && !ref $type && length $type;
    return ( undef, "structured_data: '$type' is not a schema.org type name (letters and digits, starting with a capital)" )
        unless $type =~ $TYPE;
    my $props = $raw->{properties} // {};
    return ( undef, "structured_data: $type properties must be a mapping of property: field" )
        unless ref $props eq 'HASH';
    my %out;
    for my $p ( sort keys %$props ) {
        return ( undef, "structured_data: '$p' is not a schema.org property name (lowerCamelCase)" )
            unless $p =~ $PROP;
        return ( undef, "structured_data: '$p' is the engine's on a schedule (openingHoursSpecification comes from the schedule)" )
            if $schedule && $p eq 'openingHoursSpecification';
        my $v = $props->{$p};
        if ( ref $v eq 'HASH' ) {
            return ( undef, "structured_data: '$p' nests deeper than $MAX_DEPTH objects" )
                if $depth >= $MAX_DEPTH;
            my ( $o, $why ) = _check_object( $v, $fields, $key, $owned, $schedule, $depth + 1 );
            return ( undef, $why ) if $why;
            $out{$p} = $o;
            next;
        }
        return ( undef, "structured_data: '$p' must name a field, a literal written =text, or a nested object" )
            unless defined $v && !ref $v && length $v;
        if ( $v =~ /\A=(.*)\z/s ) {
            my $lit = $1;
            return ( undef, "structured_data: '$p' literal is longer than 500 characters" )
                if length $lit > 500;
            $out{$p} = { literal => $lit };
            next;
        }
        return ( undef, "structured_data: '$p' names '$v' - a schedule's properties are literals (=text), because the schedule is one place, not a row each" )
            if $schedule;
        return ( undef, "structured_data: '$p' names '$v', which is not a field of the table" )
            unless exists $fields->{$v} || $v eq $key || ( $owned && $owned->($v) );
        $out{$p} = { field => $v };
    }
    return ( { type => $type, properties => \%out }, undef );
}

# --- encoding ----------------------------------------------------------------------

# JSON that is inert inside a <script> element and anywhere else HTML might hold it.
sub encode_inert {
    my ($data) = @_;
    my $json = JSON::PP->new->canonical->ascii->encode($data);
    $json =~ s/</\\u003c/g;
    $json =~ s/>/\\u003e/g;
    $json =~ s/&/\\u0026/g;
    return $json;
}

sub script_block {
    my (@graph) = @_;
    return '' unless @graph;
    my $doc = @graph == 1
        ? { '@context' => 'https://schema.org', %{ $graph[0] } }
        : { '@context' => 'https://schema.org', '@graph' => \@graph };
    return '<script type="application/ld+json">' . encode_inert($doc) . '</script>';
}

# --- building ------------------------------------------------------------------------

sub _value {
    my ( $spec, $row, $prop ) = @_;
    if ( exists $spec->{literal} ) { return $spec->{literal} }
    my $v = $row->{ $spec->{field} };
    return undef unless defined $v && length $v;
    return undef if $LINK_PROP{$prop} && Lazysite::Util::unsafe_link_scheme($v);
    return $v;
}

sub _build {
    my ( $obj, $row ) = @_;
    my %o = ( '@type' => $obj->{type} );
    for my $p ( sort keys %{ $obj->{properties} } ) {
        my $spec = $obj->{properties}{$p};
        if ( exists $spec->{type} ) {
            my $nested = _build( $spec, $row );
            $o{$p} = $nested if keys %$nested > 1;
            next;
        }
        my $v = _value( $spec, $row, $p );
        $o{$p} = $v if defined $v;
    }
    return \%o;
}

# Every mapping, as [ table, mapping, descriptor path ] - from the tables that
# declare one. Cheap to ask: a descriptor without the key is not parsed twice.
sub mappings {
    my ($docroot) = @_;
    require Lazysite::Data::Tables;
    my @out;
    my $dir = Lazysite::Data::Tables::descriptor_dir($docroot);
    for my $name ( @{ Lazysite::Data::Tables::list_tables($docroot) } ) {
        my ($file) = grep { -f $_ } ( "$dir/$name.yaml", "$dir/$name.yml" );
        next unless $file;
        next unless _mentions_key($file);
        my $d = Lazysite::Data::Tables::load_table( $docroot, $name );
        next unless $d->{ok} && $d->{structured_data};
        push @out, [ $name, $d->{structured_data}, $file, $d ];
    }
    return \@out;
}

sub _mentions_key {
    my ($file) = @_;
    open my $fh, '<', $file or return 0;
    while ( my $l = <$fh> ) {
        if ( $l =~ /^structured_data\s*:/ ) { close $fh; return 1 }
    }
    close $fh;
    return 0;
}

# The objects one mapping emits, from the rows an anonymous visitor may read
# now. Returns { ok, objects => [...], expires => epoch|undef, [error, kind] }.
sub objects_for {
    my ( $docroot, $table, $map, %opt ) = @_;
    require Lazysite::Data::Tables;
    my $anon = { user => '', groups => [] };
    if ( $map->{schedule} ) {
        my $r = Lazysite::Data::Tables::resolve_binding( $docroot, "$table(limit=500)", $anon );
        return { ok => 0, objects => [], error => $r->{error}, kind => $r->{kind} } unless $r->{ok};
        require Lazysite::Data::Schedule;
        my ($tz) = Lazysite::Data::Schedule::site_zone($docroot);
        my $o = _build( $map, {} );
        $o->{openingHoursSpecification}
            = Lazysite::Data::Schedule::opening_hours_spec( $r->{rows}, $tz, $opt{now} );
        my $s = Lazysite::Data::Schedule::state( $r->{rows}, $tz, $opt{now} );
        return { ok => 1, objects => [$o], expires => _sooner( $r->{expires}, $s->{expires} ) };
    }
    my $r = Lazysite::Data::Tables::resolve_binding( $docroot, "$table(limit=$MAX_ROWS)", $anon );
    return { ok => 0, objects => [], error => $r->{error}, kind => $r->{kind} } unless $r->{ok};
    my @objs = map { _build( $map, $_ ) } @{ $r->{rows} || [] };
    return { ok => 1, objects => \@objs, expires => $r->{expires} };
}

sub _sooner {
    my @t = grep { defined } @_;
    return undef unless @t;
    my ($min) = sort { $a <=> $b } @t;
    return $min;
}

# What a page carries: { graph => [...], tables => [names], files => [descriptor
# paths], expires => epoch|undef }. $url is the page's clean path (/events).
sub for_page {
    my ( $docroot, $url, %opt ) = @_;
    ( my $u = $url // '' ) =~ s{(?<=.)/\z}{};
    my ( @graph, @tables, @files, $expires );
    for my $m ( @{ mappings($docroot) } ) {
        my ( $table, $map, $file ) = @$m;
        push @files, $file;
        next unless grep { $_ eq $u } @{ $map->{pages} };
        push @tables, $table;
        my $r = objects_for( $docroot, $table, $map, %opt );
        next unless $r->{ok};
        push @graph, @{ $r->{objects} };
        $expires = _sooner( $expires, $r->{expires} );
    }
    return { graph => \@graph, tables => \@tables, files => \@files, expires => $expires };
}

# The organisation entry, from the site's own details. $site holds the raw conf
# values: site_name, site_url, site_type, site_address, site_phone, site_email,
# site_hours (a schedule table). Returns ( \%object, \@tables, $expires ).
sub organisation {
    my ( $docroot, $site, %opt ) = @_;
    my $name = $site->{site_name} // '';
    return ( undef, [], undef ) unless length $name;
    my $type = $site->{site_type} // '';
    $type = 'Organization' unless $type =~ $TYPE;
    my %o = ( '@type' => $type, name => $name );
    $o{url} = $site->{site_url}
        if length( $site->{site_url} // '' ) && $site->{site_url} =~ m{\Ahttps?://}i;
    $o{address}   = $site->{site_address} if length( $site->{site_address} // '' );
    $o{telephone} = $site->{site_phone}   if length( $site->{site_phone}   // '' );
    $o{email}     = $site->{site_email}   if length( $site->{site_email}   // '' );
    my ( @tables, $expires );
    my $hours = $site->{site_hours} // '';
    if ( $hours =~ /\A[a-z][a-z0-9_]*\z/ ) {
        require Lazysite::Data::Tables;
        my $d = Lazysite::Data::Tables::load_table( $docroot, $hours );
        if ( $d->{ok} && $d->{schedule} ) {
            push @tables, $hours;
            my $r = Lazysite::Data::Tables::resolve_binding( $docroot, "$hours(limit=500)",
                { user => '', groups => [] } );
            if ( $r->{ok} ) {
                require Lazysite::Data::Schedule;
                my ($tz) = Lazysite::Data::Schedule::site_zone($docroot);
                my $spec = Lazysite::Data::Schedule::opening_hours_spec( $r->{rows}, $tz, $opt{now} );
                $o{openingHoursSpecification} = $spec if @$spec;
                $expires = Lazysite::Data::Schedule::state( $r->{rows}, $tz, $opt{now} )->{expires};
                ${ $opt{lines} } = Lazysite::Data::Schedule::hours_lines( $r->{rows}, $tz, $opt{now} )
                    if ref $opt{lines} eq 'SCALAR';
            }
        }
    }
    return ( \%o, \@tables, $expires );
}

# --- checking (lazysite check) --------------------------------------------------------

# Findings for one emitted object against its mapping's type: a list of
# sentences, empty when it holds.
sub object_findings {
    my ( $o, $want_type, $where ) = @_;
    my @f;
    my $type = $o->{'@type'} // '';
    push @f, "$where: \@type is '$type', the mapping says '$want_type'" if $type ne $want_type;
    for my $p ( @{ $REQUIRED{$type} || [] } ) {
        push @f, "$where: $type has no $p" unless defined $o->{$p} && length $o->{$p};
    }
    for my $p ( sort keys %$o ) {
        my $v = $o->{$p};
        if ( ref $v eq 'HASH' ) {
            push @f, object_findings( $v, $v->{'@type'} // '', "$where $p" );
            next;
        }
        next unless $DATE_PROP{$p} && defined $v && !ref $v;
        push @f, "$where: $p '$v' is not an ISO 8601 date"
            unless $v =~ /\A\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:?\d{2})?)?\z/;
    }
    return @f;
}

# Every mapping's emitted JSON-LD, checked. Returns
# { findings => [...], notes => [...], mappings => N }.
sub validate_site {
    my ( $docroot, %opt ) = @_;
    my ( @findings, @notes );
    my $maps = mappings($docroot);
    for my $m (@$maps) {
        my ( $table, $map ) = @$m;
        for my $p ( @{ $map->{pages} } ) {
            ( my $rel = $p ) =~ s{\A/}{};
            my $file = length $rel ? "$docroot/$rel" : "$docroot/index";
            push @findings, "table '$table': structured_data names page $p, which this site does not have"
                unless -f "$file.md" || -f "$file/index.md";
        }
        my $r = objects_for( $docroot, $table, $map, %opt );
        unless ( $r->{ok} ) {
            push @findings, "table '$table': structured_data emits nothing - "
                . ( ( $r->{kind} // '' ) eq 'no_such_table'
                ? 'the table is not public, so no visitor (and no search engine) may read it'
                : ( $r->{error} // 'its rows could not be read' ) );
            next;
        }
        push @notes, "table '$table': $map->{type} is not a type lazysite check knows the essentials of; it is emitted as mapped and not checked"
            unless known_type( $map->{type} );
        my $i = 0;
        for my $o ( @{ $r->{objects} } ) {
            $i++;
            my $round = eval { JSON::PP->new->decode( encode_inert($o) ) };
            push @findings, "table '$table' row $i: the JSON-LD does not read back as JSON" unless $round;
            push @findings, object_findings( $o, $map->{type}, "table '$table' row $i" );
        }
    }
    return { findings => \@findings, notes => \@notes, mappings => scalar @$maps };
}

1;
