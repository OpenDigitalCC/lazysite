#!/usr/bin/perl
# SM447: field descriptors REJECT. They do not warn, and they do not repair.
#
# The data layer's premise is that an agent persists and recalls data without
# seeing SQL, and that typing is strict BECAUSE agents do the work. Everything
# downstream reads its identifiers and types from the descriptor, so this is
# the boundary.
#
# Two jobs, and the tests are grouped by them:
#
#   TYPING - a mistyped datum is corruption, not a cosmetic fault. This
#   deliberately inverts the theme layer, where a missing token falls back
#   gracefully. Here there is no permissive default, because a default is
#   exactly how an unknown type becomes a silent text column.
#
#   IDENTIFIER SAFETY - values reach SQL as bound parameters, but identifiers
#   CANNOT be bound; they are interpolated into generated statements. So this
#   validation is the whole defence, and it runs at LOAD rather than at query
#   time. A name that passes here needs no escaping anywhere downstream, which
#   is the property the rest of the plugin is allowed to assume.
#
# A loader that warns is indistinguishable from one that rejects until
# something malformed arrives - so every case below asserts the REFUSAL, and
# the accept cases exist so that "rejects everything" cannot pass either.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Data::Descriptor qw(load_descriptor TYPES);

sub good_fields { return { title => { type => 'text', max => 200 } } }

sub load { return load_descriptor( $_[0], $_[1] ) }

subtest 'a well-formed descriptor loads' => sub {
    # Without this, a loader that refused everything would pass every other
    # assertion in the file.
    my $d = load( 'tasks', {
            title  => 'Tasks',
            fields => {
                title    => { type => 'text',    required => 1,    max    => 200 },
                notes    => { type => 'text',    max      => 4000, widget => 'textarea' },
                done     => { type => 'boolean', default  => 0 },
                due      => { type => 'date' },
                priority => { type => 'enum', values => [qw(low normal high)],
                    default => 'normal' },
                cost => { type => 'decimal', digits => 10, places => 2 },
                rank => { type => 'integer', min    => 0,  max    => 9 },
            },
            indexes     => [ ['done'], [ 'priority', 'due' ] ],
            writable_by => ['members'],
            timestamps  => 1,
    } );
    ok( $d->{ok}, 'loads' ) or diag explain $d;
    is( $d->{key},        'id', 'defaults to the automatic key' );
    is( $d->{auto_key},   1,    'flagged as automatic' );
    is( $d->{timestamps}, 1,    'timestamps carried through' );
};

subtest 'IDENTIFIERS: anything that would need escaping is refused' => sub {
    # These are interpolated into generated SQL because SQL cannot bind an
    # identifier. Each of these is a name an engine might accept and we will
    # not, so nothing downstream has to quote.
    for my $bad ( 'tasks; drop table x', 'Tasks', '1tasks', 'my-table',
        'my.table', 'my table', q{tasks'}, 'tasks"', '', 'tasks`' )
    {
        my $d = load( $bad, { fields => good_fields() } );
        ok( !$d->{ok}, "table name refused: '" . ( $bad // '' ) . "'" )
            or diag( 'An identifier that reaches generated SQL unescaped is '
                . 'the injection this validation exists to prevent.' );
        is( $d->{kind}, 'descriptor', '...as a descriptor fault' );
    }

    for my $bad ( 'Title', 'field-name', 'field.name', '2nd', q{x'y} ) {
        my $d = load( 'tasks', { fields => { $bad => { type => 'text' } } } );
        ok( !$d->{ok}, "field name refused: '$bad'" );
        is( $d->{rule}, 'identifier', '...naming the rule broken' );
    }
};

subtest 'TYPES: unknown is refused, never defaulted' => sub {
    my $d = load( 'tasks', { fields => { x => { type => 'jsonb' } } } );
    ok( !$d->{ok}, 'an unknown type is refused' )
        or diag( 'A permissive default is how an unknown type becomes a '
            . 'silent text column, and the corruption arrives later.' );
    like( $d->{error}, qr/unknown type/, 'says so' );
    like( $d->{error}, qr/text/,         'and lists what IS accepted' );

    my $n = load( 'tasks', { fields => { x => {} } } );
    ok( !$n->{ok}, 'a field with no type at all is refused' );
};

subtest 'ENUM: a closed list must actually be closed' => sub {
    ok( !load( 't', { fields => { s => { type => 'enum' } } } )->{ok},
        'enum without values is refused' );
    ok( !load( 't', { fields => { s => { type => 'enum', values => [] } } } )->{ok},
        'an empty values list is refused' );
    ok( !load( 't', { fields => { s => { type => 'enum', values => [qw(a a)] } } } )->{ok},
        'duplicate values are refused' );

    my $d = load( 't', { fields => { s => { type => 'enum',
                    values => [qw(a b)], default => 'c' } } } );
    ok( !$d->{ok}, 'a default outside the list is refused' )
        or diag( 'A default that is not a member writes an invalid row on '
            . 'the first insert that omits the field.' );

    ok( !load( 't', { fields => { s => { type => 'text', values => [qw(a b)] } } } )->{ok},
        "'values' on a non-enum is refused - it reads as a constraint and enforces nothing" );
};

subtest 'DECIMAL: money is never a float' => sub {
    ok( !load( 't', { fields => { c => { type => 'decimal' } } } )->{ok},
        'decimal without digits/places is refused' );
    ok( !load( 't', { fields => { c => { type => 'decimal', digits => 10 } } } )->{ok},
        'places is required too' );
    ok( !load( 't', { fields => { c => { type => 'decimal', digits => 2, places => 5 } } } )->{ok},
        'places cannot exceed digits' )
        or diag( 'A decimal without declared precision is a float wearing a '
            . 'name, which is the thing the type exists to avoid.' );
};

subtest 'bounds that cannot be satisfied are refused' => sub {
    ok( !load( 't', { fields => { n => { type => 'integer', min => 9, max => 1 } } } )->{ok},
        'min above max is refused' );
    ok( !load( 't', { fields => { s => { type => 'text', max => 0 } } } )->{ok},
        'a zero max is refused' );
    ok( !load( 't', { fields => { s => { type => 'text', widget => 'canvas' } } } )->{ok},
        'an unknown widget is refused' );
};

subtest 'KEYS: the key must exist and be usable as one' => sub {
    my $d = load( 't', { key => 'slug', fields => good_fields() } );
    ok( !$d->{ok}, 'a key naming no field is refused' );
    is( $d->{rule}, 'key', '...as a key fault' );

    ok( !load( 't', { key => 'n', fields => { n => { type => 'integer' } } } )->{ok},
        'a natural key must be text' );

    ok( !load( 't', { fields => { id => { type => 'text' } } } )->{ok},
        "declaring 'id' as a field collides with the automatic key" )
        or diag( 'Two things would own the same column and the DDL would be '
            . 'ambiguous - better refused than resolved by precedence.' );

    my $ok = load( 't', { key => 'slug',
            fields => { slug => { type => 'text' }, x => { type => 'text' } } } );
    ok( $ok->{ok}, 'a text natural key is accepted' );
    is( $ok->{auto_key}, 0, 'and is not flagged automatic' );
};

subtest 'the plugin owns the timestamp columns' => sub {
    for my $f (qw(created_at updated_at)) {
        my $d = load( 't', { fields => { $f => { type => 'datetime' } } } );
        ok( !$d->{ok}, "declaring '$f' is refused" );
        is( $d->{rule}, 'reserved', '...as reserved' );
    }
};

subtest 'indexes and writable_by name real things' => sub {
    ok( !load( 't', { fields => good_fields(), indexes => [ ['nope'] ] } )->{ok},
        'an index naming an undeclared field is refused' );
    ok( !load( 't', { fields => good_fields(), indexes => ['title'] } )->{ok},
        'an index must be a LIST of fields, not a bare name' );
    ok( !load( 't', { fields => good_fields(), writable_by => ['bad group!'] } )->{ok},
        'a group name that is not a plain name is refused' );
    ok( load( 't', { fields => good_fields(), indexes => [ ['title'] ] } )->{ok},
        'a well-formed index is accepted' );
};

subtest 'shape faults are refused before anything else looks at them' => sub {
    ok( !load( 't', 'not a mapping' )->{ok},  'a non-mapping descriptor' );
    ok( !load( 't', {} )->{ok},               'no fields at all' );
    ok( !load( 't', { fields => {} } )->{ok}, 'an empty fields mapping' );
    ok( !load( 't', { fields => { x => 'text' } } )->{ok},
        'a field whose spec is a bare string, not a mapping' );
};

subtest 'SM519: no means no - every boolean spelling means what it says' => sub {
    # YAML::PP implements YAML 1.2, where `no`, `off`, `yes` and `on` are plain
    # STRINGS. A loader testing Perl truth reads `public: no` as public, which
    # exposes the rows to anonymous visitors. So every spelling is normalised
    # and anything else is refused rather than guessed at.
    for my $v ( 'no', 'No', 'NO', 'off', 'false', 'FALSE', 0, '0' ) {
        my $d = load( 't', { fields => good_fields(), public => $v } );
        ok( $d->{ok}, "public: $v loads" ) or diag explain $d;
        is( $d->{public}, 0, "public: $v means NOT public" );
    }
    for my $v ( 'yes', 'on', 'true', 'True', 1, '1' ) {
        my $d = load( 't', { fields => good_fields(), public => $v } );
        ok( $d->{ok}, "public: $v loads" ) or diag explain $d;
        is( $d->{public}, 1, "public: $v means public" );
    }
    is( load( 't', { fields => good_fields() } )->{public},
        0, 'absent means not public' );

    my $bad = load( 't', { fields => good_fields(), public => 'perhaps' } );
    ok( !$bad->{ok}, 'public: perhaps is REFUSED' );
    is( $bad->{error}, "table 't': public must be true or false",
        '...with the promised message' );
    is( $bad->{rule}, 'public', '...and the rule names the key' );

    for my $v ( 'no', 'off', 'False' ) {
        my $d = load( 't', { fields => good_fields(), timestamps => $v } );
        is( $d->{timestamps}, 0, "timestamps: $v means no timestamps" );
    }
    $bad = load( 't', { fields => good_fields(), timestamps => 'perhaps' } );
    is( $bad->{error}, "table 't': timestamps must be true or false",
        'timestamps: perhaps is refused with the promised message' );

    for my $v ( 'no', 'off', 'False' ) {
        my $d = load( 't',
            { fields => { code => { type => 'text', unique => $v, required => $v } } } );
        ok( $d->{ok}, "unique/required: $v loads" ) or diag explain $d;
        is_deeply( $d->{unique}, [], "unique: $v means NOT unique" );
        is( $d->{fields}{code}{required}, 0,
            "required: $v is written back as 0 for every downstream reader" );
    }
    my $d = load( 't',
        { fields => { code => { type => 'text', unique => 'yes', required => 'on' } } } );
    is_deeply( $d->{unique}, ['code'], 'unique: yes means unique' );
    is( $d->{fields}{code}{required}, 1, 'required: on is written back as 1' );

    for my $k (qw(unique required)) {
        $bad = load( 't', { fields => { code => { type => 'text', $k => 'perhaps' } } } );
        ok( !$bad->{ok}, "$k: perhaps is REFUSED" );
        is( $bad->{error}, "table 't': field 'code': $k must be true or false",
            '...with the promised message' );
        is( $bad->{field}, 'code', '...naming the field' );
    }

SKIP: {
        skip 'YAML::PP not installed', 4 unless eval { require YAML::PP; 1 };
        # The real path: text, through the real parser, exactly as the probe
        # that found this did.
        my $raw = YAML::PP->new->load_string(<<'YAML');
fields:
  name:
    type: text
    required: no
  code:
    type: text
    unique: off
public: no
timestamps: No
YAML
        my $t = load( 'probe', $raw );
        ok( $t->{ok}, 'the probe descriptor loads' ) or diag explain $t;
        is( $t->{public},     0, 'public: no means not public' );
        is( $t->{timestamps}, 0, 'timestamps: No means no timestamps' );
        is_deeply( $t->{unique}, [], 'unique: off means not unique' );
    }
};

subtest 'SM586: the YAML parser\'s own false is false' => sub {
    # SM519 normalised the boolean SPELLINGS and was tested with hashes, so
    # nothing exercised what YAML::PP actually hands back for a bare `false`:
    # a DEFINED, ZERO-LENGTH string, which matched neither the true nor the
    # false set and was refused. The one value meaning "private" was the one
    # that failed, on a live site, for a whole release. So this subtest drives
    # the YAML TEXT rather than a hash - if the parser's representation ever
    # changes again, this assertion is what notices.
SKIP: {
        skip 'YAML::PP not available', 8 unless eval { require YAML::PP; 1 };
        my $yaml = sub {
            my ($v) = @_;
            return YAML::PP->new->load_string(
                "title: T\nkey: slug\npublic: $v\nfields:\n  slug:\n    type: text\n");
        };
        for my $case ( [ 'false', 0 ], [ 'true', 1 ], [ "'false'", 0 ],
            [ '0', 0 ], [ 'no', 0 ], [ 'off', 0 ] )
        {
            my ( $spelling, $want ) = @{$case};
            my $d = load_descriptor( 'zzpub', $yaml->($spelling) );
            ok( $d->{ok}, "public: $spelling loads" )
                or diag( $d->{error} // 'no error given' );
            is( $d->{public}, $want, "public: $spelling means " . ( $want ? 'public' : 'private' ) );
        }
    }
};

done_testing();
