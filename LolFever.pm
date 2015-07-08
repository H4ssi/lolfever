# LoLfever - random meta ftw
# Copyright (C) 2013, 2015  Florian Hassanen
# 
# This file is part of LoLfever.
#
# LoLfever is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package LolFever;

use Modern::Perl '2015';
use feature 'signatures';

use Mojolicious::Lite;

use Mojo::Path;
use Mojo::Pg;
use Mojo::IOLoop;

use Digest;
use Bytes::Random::Secure qw<random_bytes>;
use Crypt::ScryptKDF qw<scrypt_hash scrypt_hash_verify>;

use feature 'postderef';
no warnings 'experimental::postderef';
no warnings 'experimental::smartmatch';
no warnings 'experimental::signatures';

my $config = plugin 'Config';
my $base = $config->{'base'} // '';
my $lol_api_key = $config->{'lol_api_key'};
my $pg = Mojo::Pg->new( $config->{connection_string} );

app->secrets($config->{'secrets'});
random_bytes(32); # get rng seeded (this might block)
my $legacy_sha_salt = $config->{'legacy_sha_salt'};
app->defaults( layout => 'layout' );
app->ua->max_redirects(10);

my @base_path = @{ Mojo::Path->new($base)->leading_slash(0) };
app->hook(before_dispatch => sub ($c) {
  my @base = splice @{ $c->req->url->path->leading_slash(0) }, 0, scalar @base_path;

  $c->rendered(404) unless @base ~~ @base_path;

  push @{ $c->req->url->base->path->trailing_slash(1) }, @base;
});

app->sessions->cookie_name('lolfever');
app->sessions->cookie_path(Mojo::Path->new($base)->leading_slash(1)->trailing_slash(1)->to_string);
app->sessions->secure(app->mode ne 'development');

my %PARSE = ( mid => 'mid', 
              top => 'top',
              support => 'sup',
              adcarry => 'ad|bot',
              jungle => 'jun', );

my @ROLES = keys %PARSE;

sub parse_role( $role_string ) {
    for my $role (@ROLES) {
        return $role if $role_string =~ /$PARSE{$role}/xmsi;
    }
    return;
}

sub pg_setup ( $data, $version, $action ) {
    if ( $data->{schema_version} < $version ) {
        $action->();
        $data->{schema_version} = $version;
        $pg->db->query('update meta set data = ?::jsonb', { json => $data });
    }
}

sub pg_init() {
    $pg->db->query('create table if not exists meta (id integer primary key check (id = 0), data jsonb)');
    my $data = $pg->db->query('select data from meta')->expand->arrays->first;
    unless ($data) {
        $data = [{ schema_version => 0 }];
        $pg->db->query('insert into meta (id, data) values (0, ?::jsonb)', { json => $data->[0] });        
    }
    $data = $data->[0];

    pg_setup($data, 1, sub {
        $pg->db->query('create table champion (id integer primary key, key text unique, name text)')
    });
    pg_setup($data, 2, sub {
        $pg->db->query('alter table champion alter key set not null');
        $pg->db->query('alter table champion alter name set not null');
    });
    pg_setup($data, 3, sub {
        $pg->db->query("alter table champion add free boolean not null default 'f'");
    });
    pg_setup($data, 4, sub {
        $pg->db->query("alter table champion add roles jsonb not null default '{}'::jsonb");
    });
    pg_setup($data, 5, sub {
        $pg->db->query("alter table champion add blacklist jsonb not null default '{}'::jsonb, add whitelist jsonb not null default '{}'::jsonb");
    });
    pg_setup($data, 6, sub {
        $pg->db->query('create table summoner (id serial primary key, name text unique not null, pw text not null, pwhash text)');
    });
    pg_setup($data, 7, sub {
        $pg->db->query("alter table summoner add roles jsonb not null default '{}'::jsonb");
    });
    pg_setup($data, 8, sub {
        $pg->db->query("alter table summoner add champions jsonb not null default '{}'::jsonb");
    });
    pg_setup($data, 9, sub {
        $pg->db->query("alter table champion add image text not null default 'Unknown.png'");
        $pg->db->query("alter table champion alter image drop default");
    });
    pg_setup($data, 10, sub {
        $pg->db->query('create table global (id integer primary key check (id = 0), data jsonb)');
        $pg->db->query("insert into global (id, data) values (0, '{}'::jsonb)");
    });
    pg_setup($data, 11, sub {
        $pg->db->query("alter table summoner add admin boolean not null default 'f'");
    });
    pg_setup($data, 12, sub {
        $pg->db->query("alter table summoner drop pw");
        $pg->db->query("alter table summoner add pw_change_required boolean not null default 'f'");
    });
    pg_setup($data, 13, sub {
        $pg->db->query("create function notify_global_modified_trigger() returns trigger as \$\$ begin notify lolfever_global_modified; return null; end; \$\$ language plpgsql");
        $pg->db->query("create trigger global_modified_trigger after update on global for each row when (old.data != new.data) execute procedure notify_global_modified_trigger()");
    });
}

sub store_champs( $champs, $cb ) {
    my $h = $pg->db;
    my $tx = $h->begin;

    my $handler = sub ($c) {
        return sub ($d, @) {
                my $cb = $d->begin;
                $h->query('update champion set (key, name, free, roles, image) = (?, ?, ?, ?::jsonb, ?) where id = ? returning id',
                    $c->{key}, $c->{name}, $c->{free} ? 't' : 'f', { json => $c->{roles} }, $c->{image}, $c->{id},
                    sub ($, $, $r) {
                        if ($r->arrays->size) {
                            $cb->();
                        } else {
                            $h->query('insert into champion (id, key, name, free, roles, image) values (?, ?, ?, ?, ?::jsonb, ?)',
                                $c->{id}, $c->{key}, $c->{name}, $c->{free} ? 't' : 'f', { json => $c->{roles} }, $c->{image},
                                $cb);
                        }
                    });
        }
    };

    Mojo::IOLoop->delay(
        (map { $handler->($_) } (values %$champs)),
        sub (@) {
            $tx->commit;
            $cb->(undef);
        });
}

sub get_champs($cb) {
    $pg->db->query('select * from champion order by name', sub ($,$,$r) { $cb->(undef, $r->expand->hashes); });
}

sub alter_anylist( $champ_key, $role, $cb, $list_name, $op ) {
    $pg->db->query("update champion
                    set $list_name = (select coalesce(json_object_agg(key, value), '{}')::jsonb
                                      from (select * from jsonb_each($list_name)
                                            $op
                                            select ?, 'null'::jsonb) i)
                    where key = ?", 
                    $role, $champ_key,
                    sub (@) { $cb->(undef) });
}

sub add_blacklist( $champ_key, $role, $cb ) {
    alter_anylist( $champ_key, $role, $cb, 'blacklist', 'union' );
}

sub add_whitelist( $champ_key, $role, $cb ) {
    alter_anylist( $champ_key, $role, $cb, 'whitelist', 'union' );
}

sub remove_blacklist( $champ_key, $role, $cb ) {
    alter_anylist( $champ_key, $role, $cb, 'blacklist', 'except' );
}

sub remove_whitelist( $champ_key, $role, $cb ) {
    alter_anylist( $champ_key, $role, $cb, 'whitelist', 'except' );
}

sub save_user( $user, $cb ) {
    $pg->db->query("update summoner set (pwhash, pw_change_required, roles, champions) = (?, ?, ?::jsonb, ?::jsonb) where name = ?",
        $user->{pwhash}, $user->{pw_change_required} ? 't' : 'f', {json => $user->{roles}}, {json => $user->{champions}}, $user->{name},
        sub (@) { $cb->(undef); });
}

sub get_users( $cb ) {
    $pg->db->query('select * from summoner order by name', sub ($,$,$r) { $cb->(undef, $r->expand->hashes); });
}

sub get_user( $name, $cb ) {
    $pg->db->query('select * from summoner where name = ?', $name, sub ($,$,$r) { $cb->(undef, $r->expand->hashes->first); });
}
app->hook(around_action => sub ($next, $c, @) {
    my $s = $c->session;
    if ( exists $s->{logged_in} ) {
        $c->render_later;
        $c->delay(
            sub ($d) {
                get_user( $s->{logged_in}, $d->begin );
            },
            sub ($d, $user) {
                $c->stash(logged_in => $user);
                $next->();
            });
    } else {
        $next->();
    }
});
get('/logout' => sub ($c) {
    $c->session(expires => 1);
    $c->redirect_to('home');
});
sub get_global_data( $cb ) {
    return $pg->db->query('select data from global', sub ($,$,$r) { $cb->(undef, $r->expand->hashes->first->{data}); });
}

sub save_global_data($data) {
    $pg->db->query('update global set data = ?::jsonb', {json => $data}, sub(@) {});
}

my $global_data;
sub load_global_data() {
    Mojo::IOLoop->delay(
        sub($d) { get_global_data($d->begin); },
        sub($d, $data) { $global_data = $data; });
}
helper global_data => sub ($self, $data = undef) {
    if( defined $data ) {
        $global_data = $data;
        save_global_data($global_data);
    }
    return $global_data;
};

post("/championdb" => sub ($c) {
    my @errors;

    $c->render_later;
    $c->delay(
        sub ($d) {
            $c->ua->get("https://global.api.pvp.net/api/lol/static-data/euw/v1.2/realm?api_key=$lol_api_key" => $d->begin);
            $c->ua->get("https://euw.api.pvp.net/api/lol/euw/v1.2/champion?api_key=$lol_api_key" => $d->begin);
            $c->ua->get("https://global.api.pvp.net/api/lol/static-data/euw/v1.2/champion?dataById=true&champData=image&api_key=$lol_api_key" => $d->begin);
            $c->ua->get('http://www.lolking.net/champions' => $d->begin);
            $c->ua->get('http://www.lolking.net/guides' => $d->begin);
            $c->ua->get('http://www.lolpro.com' => $d->begin);
        },
        sub ($d, $realm_tx, $champions_tx, $static_tx, $champs_tx, $guides_tx, $roles_tx) {
            $c->global_data({ %{$realm_tx->res->json}{qw<cdn dd>}});

            my $champions = $champions_tx->res->json->{'champions'};
            my $static = $static_tx->res->json->{'data'};

            my $ids = { map { (lc $_->{key}) => $_->{id} } (values %$static) };
            my $champs = { map { $_->{id} => { id => $_->{id},
                                               key => lc $static->{$_->{id}}{key},
                                               name => $static->{$_->{id}}{name},
                                               free => !!$_->{freeToPlay},
                                               image => $static->{$_->{id}}{image}{full},
                                               roles => {},} } @$champions };

            for my $champ ( $champs_tx->res->dom->find('.champion-list tr')->@* ) {
                my $a = $champ->at('.champion-list-icon > a');
                if( defined $a ) {
                    unless( $a->attr('href') =~ / ( [^\/]*? ) \z/xms ) {
                        push @errors, 'Could not parse champion name from: '.($a->attr('href'));
                    } else {
                        my $key = $1;

                        unless( exists $ids->{$key} ) {
                            push @errors, "What is this champion: $key";
                        } else {
                            my $role = $champ->at('td:nth-last-of-type(2)');
                            unless( defined $role && defined $role->attr('data-sortval') ) {
                                push @errors, "No role found for champion $key";
                            } else {
                                my $r = parse_role($role->attr('data-sortval'));
                                
                                unless( defined $r ) {
                                    push @errors, "Do not know what role this is: '".($role->attr('data-sortval'))."' (champion is '$key')";
                                } else {
                                    $champs->{$ids->{$key}}{roles}{$r} = undef;
                                }
                            }
                        }
                    }
                }
            }

            for my $champ ( $guides_tx->res->dom->find('#guides-champion-list > .big-champion-icon')->@* ) {
                my ($key) = $champ->attr('href') =~ /champion=([a-z]*)/xms;
                my @roles = map { $champ->attr("data-meta$_") } @{['', 1..5]};
         
                unless( exists $ids->{$key} ) {
                    push @errors, "No such champion: $key";
                } else {
                    for my $role (@roles) {
                        next unless defined $role;
                        next unless $role =~ /\w/xms;

                        my $r = parse_role($role);

                        unless( $r ) {
                            push @errors, "Do not know what role this is again: '$role' (champion is '$key')";
                        } else {
                            $champs->{$ids->{$key}}{roles}{$r} = undef;
                        }
                    }
                }
            }

            for my $champ ( $roles_tx->res->dom->find('li.game-champion')->@* ) {
                my @classes = split /\s+/xms, $champ->attr('class');

                my ($key_info) = grep { /\A game-champion-/xms && !/\A game-champion-tag-/xms } @classes;

                if( $key_info =~ /\A game-champion-(.*) \z/xms ) {
                    my $key = $1 =~ s/[^a-z]//xmsgr;
                    $key = 'monkeyking' if $key eq 'wukong';

                    unless( exists $ids->{$key} ) {
                        push @errors, "What is this for a champion: $key?";
                    } else {
                        $champs->{$ids->{$key}}{roles}{'top'}     = undef if 'game-champion-tag-top'      ~~ @classes;
                        $champs->{$ids->{$key}}{roles}{'mid'}     = undef if 'game-champion-tag-mid'      ~~ @classes;
                        $champs->{$ids->{$key}}{roles}{'adcarry'} = undef if 'game-champion-tag-duo'      ~~ @classes && !( 'game-champion-tag-support' ~~ @classes );
                        $champs->{$ids->{$key}}{roles}{'support'} = undef if 'game-champion-tag-support'  ~~ @classes;
                        $champs->{$ids->{$key}}{roles}{'jungle'}  = undef if 'game-champion-tag-jungler'  ~~ @classes;

                    }
                }
            }

            store_champs($champs, $d->begin);
        },
        sub ($d) { get_champs($d->begin); },
        sub ($d, $champs) {
            $c->render('championdb', errors => ( @errors ? \@errors : undef ), champs => $champs, updated => 1, roles => [ sort @ROLES ], mode => 'champions');
        }
    );
})->name('championdb');

get( "/champion/:champion/:role/blacklist" => sub ($c) {
    $c->render_later;
    $c->delay(
        sub ($d) { add_blacklist( $c->param('champion'), $c->param('role'), $d->begin ); },
        sub ($d) { $c->redirect_to('championdb'); });
})->name('blacklist');

get( "/champion/:champion/:role/no_blacklist" => sub ($c) {
    $c->render_later;
    $c->delay(
        sub ($d) { remove_blacklist( $c->param('champion'), $c->param('role'), $d->begin ); },  
        sub ($d) { $c->redirect_to('championdb'); });
})->name('no_blacklist');

get( "/champion/:champion/:role/whitelist" => sub ($c) {
    $c->render_later;
    $c->delay(
        sub ($d) { add_whitelist( $c->param('champion'), $c->param('role'), $d->begin ); },
        sub ($d) { $c->redirect_to('championdb'); });
})->name('whitelist');

get( "/champion/:champion/:role/no_whitelist" => sub ($c) {
    $c->render_later;
    $c->delay(
        sub ($d) { remove_whitelist( $c->param('champion'), $c->param('role'), $d->begin ); }, 
        sub ($d) { $c->redirect_to('championdb'); });
})->name('no_whitelist');

get "/championdb" => sub ($c) {
    $c->render_later;
    $c->delay(
        sub($d) { get_champs($d->begin); },
        sub($d, $champs) {
            $c->render( 'championdb', errors => undef, champs => $champs, updated => 0, roles => [ sort @ROLES ], mode => 'champions' );
        });
};

get("/user/:name" => sub ($c) {
    my $name = $c->param('name');
    return $c->render( text => "No user" ) unless defined $name;

    my $logged_in_user = $c->stash('logged_in');
    my $logged_in;
    $logged_in = $logged_in_user if $logged_in_user && $logged_in_user->{name} eq $name;

    $c->render_later;
    $c->delay(
        sub ($d) { get_user( $name, $d->begin ); },
        sub ($d, $user) {
            return $c->render( text => "No such user: $name", name => $name, mode => 'profile' ) unless $user;

            $d->pass($user);
            get_champs($d->begin);
        },
        sub($d, $user, $champs) {
            $c->render($c->param('edit') ? 'user_edit' : 'user', name => $user->{name}, user => $user, champs => $champs, roles => [ sort @ROLES ], pw_required => !$logged_in, pw_change_required => $user->{pw_change_required}, mode => 'profile' );
        });
})->name('user');

post "/user/:name" => sub ($c) {
    my $name = $c->param('name');
    return $c->render( text => "No user" ) unless defined $name;

    my $logged_in_user = $c->stash('logged_in');
    my $logged_in;
    $logged_in = $logged_in_user if $logged_in_user && $logged_in_user->{name} eq $name;
    my $logged_in_admin;
    $logged_in_admin = $logged_in_user if $logged_in_user && $logged_in_user->{admin};

    $c->render_later;
    $c->delay(
        sub($d) { 
            if( $logged_in ) {
                $d->pass($logged_in);
            } else {
                get_user($name, $d->begin);
            }
        },
        sub($d, $user) {     
            return $c->render( text => "No such user: $name", name => $name, mode => 'profile' ) unless $user;
    
            my $pw = $c->param('current_pw') // '';
            my $new_pw_1 = $c->param('new_pw_1') // '';
            my $new_pw_2 = $c->param('new_pw_2') // '';

            if ( !$logged_in || $pw ne '' || $new_pw_1 ne '' || $new_pw_2 ne '' ) {
                my $hash = $user->{pwhash};
                my $authenticated = 0;

                if( $pw ne '' ) {
                    return $c->render( text => "User deactivated: $name", name => $name, mode => 'profile' ) unless $hash;
                    
                    if( $hash =~ / \A SCRYPT: /xms ) {
                        $authenticated = 'pw' if scrypt_hash_verify( $pw, $hash );  
                    } else {
                        $authenticated = 'pw' if $hash eq Digest->new('SHA-512')->add($legacy_sha_salt)->add($pw)->b64digest;
                    }
                } elsif( $logged_in_admin && $logged_in_admin->{name} ne $user->{name} ) {
                    $authenticated = 'admin';
                } 

                return $c->render( text => 'invalid pw', name => $name, mode => 'profile' ) unless $authenticated;
                
                return $c->render( text => 'must change pw', name => $name, mode => 'profile' ) if $user->{pw_change_required} && !$new_pw_1;

                if( $new_pw_1 ne '' ) {
                    return $c->render( text => 'new pws did not match', name => $name, mode => 'profile' ) unless $new_pw_1 eq $new_pw_2;
                    
                    $user->{pwhash} = scrypt_hash($new_pw_1, random_bytes(32));
                    $user->{pw_change_required} = $authenticated eq 'admin';
                } elsif( $hash !~ / \A SCRYPT: /xms ) {
                    $user->{pwhash} = scrypt_hash($pw, random_bytes(32));
                }
        
                $c->session->{logged_in} = $user->{name} unless $authenticated eq 'admin';
            }
            $user->{roles} = { map { $_ => undef } (grep { $c->param("can:$_") } @ROLES) };

            $d->pass($user);
            get_champs($d->begin); 
        },
        sub($d, $user, $champs) {
            $user->{champions} = { map { $_->{id} => undef } (grep { $c->param("owns:$_->{key}") } @$champs) };
            save_user( $user, $d->begin );
        },
        sub($d) {
            $c->redirect_to;
        });
};

sub roll_form($c) {
    $c->render_later;
    $c->delay(
        sub ($d) { get_users($d->begin); get_champs($d->begin); },
        sub ($d, $users, $champs) {
            $c->render( 'roll', users => $users, roles => [ sort @ROLES ], champs => $champs, players => undef, needed_roles => \@ROLES, wochampions => undef, roll => undef, fails => undef, mode => 'roll' );
        });
};

get "" => \&roll_form;
get "/troll" => \&roll_form;

sub select_random( @values ) {
    my $len = scalar  @values;
    my $ran = int(rand($len));

    my @other = grep { $_ != $ran } (0..$len-1);

    return @values[$ran, @other];
}

sub all_options( $db, $user, $tabu_roles, $tabu_champions ) {
    my @tabu_champion_ids = map { $_->{id} } @$tabu_champions;
    return map {
        my $champion = $_;
        if ( ( exists $user->{champions}{$champion->{id}} || $champion->{free} ) && !( $champion->{id} ~~ @tabu_champion_ids ) ) {
            map {
                my $role = $_;
                if ( exists $user->{roles}{$role} && !( $role ~~ @$tabu_roles ) ) {
                    { champion => $champion, role => $role };
                } else { (); }
            } keys $db->{$champion->{id}}{effective_roles}->%*;
        } else { (); }
    } values %$db;
}

sub combine_blacklist_whitelist( $champs ) {
    return { map { 
        my $champ = $_;
        ( $champ->{id} => { 
            %$champ,
            effective_roles => { map {
                my $role = $_;
                if ( ( exists $champ->{roles}{$role} || exists $champ->{whitelist}{$role} ) && !exists $champ->{blacklist}{$role} ) {
                    ( $role => undef );
                } else { 
                    (); 
                } 
            } @ROLES } } );
    } @$champs };
}

sub trollify( $db ) {
    for my $champ ( keys %$db ) {
        my @roles = keys $db->{$champ}{effective_roles}->%*;
        push @roles, 'adcarry', 'support' if 'adcarry' ~~ @roles || 'support' ~~ @roles; # combine bot lane :)
        my @troll_roles = grep { !( $_ ~~ @roles ) } @ROLES;

        $db->{$champ}{effective_roles} = { map { $_ => undef } @troll_roles };
    }

    return $db;
}

sub roll( $c, $trolling = '' ) {
    my @players = grep { $_ } $c->every_param('players')->@*;
    my @needed_roles = grep { $_ } $c->every_param('needed_roles')->@*;
    my @woroles = grep { not $_ ~~ @needed_roles } @ROLES;
    my @wochampionkeys = grep { $_ } $c->every_param('wochampions')->@*;

    $c->render_later;
    $c->delay(
        sub ($d) { get_users($d->begin); get_champs($d->begin); },
        sub ($d, $users, $champs) {
            my $user_hash = { map { $_->{name} => $_ } @$users };
            my %player_specs = map { $_ => $user_hash->{$_} } @players;

            my @wochampions = grep { $_->{key} ~~ @wochampionkeys } @$champs;

            my $db = combine_blacklist_whitelist( $champs );
            $db = trollify( $db ) if $trolling;
            
            my @fails;

            my $TRIES = 42;

            my %roll;
            for (1..$TRIES) {
                my @u = @players;

                while( scalar @u ) {
                    (my $user, @u) = select_random(@u);

                    my @options = all_options($db, $player_specs{$user}, [ @woroles, map { $_->{'role'} } values %roll ], [ @wochampions, map { $_->{champion} } values %roll ]);
                    
                    unless( scalar @options ) {
                        push @fails, { $user => { %roll } };
                        last;
                    }

                    $roll{$user} = $options[ int(rand(scalar @options)) ];
                }

                last if ( scalar ( keys %roll ) ) == ( scalar @players );
                %roll = ();
            }

            my @users = map { /(.*)\.db\z/xms; $1 } (grep { !/champions|roll|free|blacklist|whitelist/xms } (glob '*.db'));

            $c->render( 'roll', users => $users, roles => [ sort @ROLES ], champs => $champs, players => \@players, needed_roles => \@needed_roles, wochampions => \@wochampionkeys, 
                         roll => (scalar keys %roll ? \%roll : undef), fails => (scalar @fails ? $c->dumper(\@fails) : undef), mode => 'roll' );
        });
}

get "/roll" => sub ($c) {
    return $c->redirect_to('home');
};

post("" => sub ($c) {
    return roll($c);
})->name('home');

post("/troll" => sub ($c) {
    return roll($c, 'trolling');
})->name('trollroll');


pg_init();
Mojo::IOLoop->next_tick(sub { 
    $pg->pubsub->listen(lolfever_global_modified => sub (@) { load_global_data(); });
    load_global_data(); 
});
app->start;

__DATA__

@@ layouts/layout.html.ep
<!DOCTYPE html>
<html lang="en">
<!--
  - LoLfever - random meta ftw
  - Copyright (C) 2013, 2015  Florian Hassanen
  - 
  - This file is part of LoLfever.
  -
  - LoLfever is free software: you can redistribute it and/or modify
  - it under the terms of the GNU Affero General Public License as
  - published by the Free Software Foundation, either version 3 of the
  - License, or (at your option) any later version.
  - 
  - This program is distributed in the hope that it will be useful,
  - but WITHOUT ANY WARRANTY; without even the implied warranty of
  - MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  - GNU Affero General Public License for more details.
  - 
  - You should have received a copy of the GNU Affero General Public License
  - along with this program.  If not, see <http://www.gnu.org/licenses/>.
  -->
<head>
<meta charset="utf-8">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>LoL Fever</title>
<link href="<%= url_for '/css/bootstrap.min.css' %>" rel="stylesheet" media="screen">
<!-- HTML5 shim and Respond.js for IE8 support of HTML5 elements and media queries -->
<!-- WARNING: Respond.js doesn't work if you view the page via file:// -->
<!--[if lt IE 9]>
  <script src="https://oss.maxcdn.com/html5shiv/3.7.2/html5shiv.min.js"></script>
  <script src="https://oss.maxcdn.com/respond/1.4.2/respond.min.js"></script>
<![endif]-->
</head>
<body>
<div class="container">
<nav class="navbar navbar-default">
    <div class="container-fluid">
        <div class="navbar-header">
            <button type="button" class="navbar-toggle collapsed" data-toggle="collapse" data-target="#navbar">
                <span class="sr-only">Toggle navigation</span>
                <span class="icon-bar"></span>
                <span class="icon-bar"></span>
                <span class="icon-bar"></span>
            </button>
            %= link_to LoLfever => 'home', {}, class => 'navbar-brand'
        </div>
        <div class="collapse navbar-collapse" id="navbar">
            <ul class="nav navbar-nav">
                <li <% if( $mode eq 'roll'      ) { %> class="active" <% } %> >
                    %= link_to Roll => 'home'
                </li>
                <li <% if( $mode eq 'champions' ) { %> class="active" <% } %> >
                    %= link_to Champions => 'championdb'          
                </li>
                <% if( $mode eq 'profile' ) { %> 
                    <li class="active">
                        %= link_to ( (stash 'name') . "'" . ( (stash 'name') =~ /s \z/xms ? '' : 's') . ' profile')                
                    </li> 
                <% } %>
            </ul>
        </div>
    </div>
</nav>
<%= content %>
<div style="margin-top: 40px" class="text-center"><small>This is free software. Get the <a href="https://github.com/H4ssi/lolfever">source</a>!</small></div>
</div>
<script src="<%= url_for '/js/jquery.min.js' %>"></script>
<script src="<%= url_for '/js/bootstrap.min.js' %>"></script>
</body>
</html>

@@ roll.html.ep

% if( defined $roll ) {
    <div class="well well-sm">
        <ul class="roll-list">
        % for my $player ( sort keys %$roll ) {
            <li>
                <span class="player"><%= $player %></span>
                <img src="<%= global_data->{cdn} %>/<%= global_data->{dd} %>/img/champion/<%= $roll->{$player}{champion}{image} %>">
                <span class="champion-name"><%= $roll->{$player}{champion}{name} %></span>
                <span class="player-role"><%= $roll->{$player}{role} %></span>
            </li>
        % }
        </ul>
    </div>
% }

%= form_for url_for() => (method => 'POST') => begin

<div class="form-group">
    <label>Players</label>
    % for my $user (@$users) {
        <div class="checkbox">
            <label>
                %= input_tag "players", type => 'checkbox', value => $user->{name}, $user->{name} ~~ @$players ? ( checked => 'checked' ) : ()
                %= link_to $user->{name} => 'user' => { name => $user->{name} }
            </label>
        </div>
    % }
</div>

<div class="form-group">
    <label>Roles</label>
    % for my $role (@$roles) {
        <div class="checkbox">
            <label>
                %= input_tag "needed_roles", type => 'checkbox', value => $role, $role ~~ @$needed_roles ? ( checked => 'checked' ) : ()
                %= $role
            </label>
        </div>
    % }
</div>

<div class="form-group">
    <label>Excluded champions</label>
    % for my $i (0..3) {
        <select name="wochampions" class="form-control">
            <option value=""></option>
            % for my $champ (@$champs) {
                <option value="<%= $champ->{key} %>"
                    % if( $champ->{key} eq ($wochampions->[$i] // '') ) {
                        selected="selected"
                    % }
                ><%= $champ->{name} %></option>
            % }
        </select>
    % }
</div>

<button type="submit" class="btn btn-default">Roll</button>

% end 
%# of form

% if( defined $fails ) {
    <pre><%= $fails %></pre>
% }


@@ user.html.ep

<h3>Possible roles</h3>
<ul class="list-inline">
% for my $role (@$roles) {
    % if( exists $user->{roles}{$role} ) {
        <li><span class="label label-default"><%= $role %></span></li>
    % }
% }
</ul>

<h3>Owned champions</h3>
<ul class="owned-champions">
% for my $champ (@$champs) {
    % if( exists $user->{champions}{$champ->{id}} ) {
        <li>
            <img src="<%= global_data->{cdn} %>/<%= global_data->{dd} %>/img/champion/<%= $champ->{image} %>">
            <div><%= $champ->{name} %></div>
        </li>
    % }
% }
</ul>

%= link_to Edit => url_for->query(edit => 1) => (class => 'btn btn-default')


@@ user_edit.html.ep

%= form_for url_for() => (method => 'POST') => begin

<div class="form-group preferred-roles">
    <label><h4>Possible roles</h4></label>
    <br>

    <div class="btn-group" data-toggle="buttons">
        % for my $role (@$roles) {
            <label  class="btn btn-default <%= exists $user->{roles}{$role} ? "active" : ""%>">
                %= input_tag "can:$role", type => 'checkbox', value => 1, autocomplete => 'off', exists $user->{roles}{$role} ? ( checked => 'checked' ) : ()
                <%= $role %>
            </label>
        % }
    </div>
</div>

<div class="form-group owned-champions">
    <label><h4>Owned champions</h4></label>
    <br>
    
    <div class="btn-group" data-toggle="buttons">
        % for my $champ (@$champs) {
            <label class="btn btn-default <%= exists $user->{champions}{$champ->{id}} ? "active" : ""%>">
                %= input_tag "owns:$champ->{key}", type => 'checkbox', value => 1, autocomplete => 'off', exists $user->{champions}{$champ->{id}} ? ( checked => 'checked' ) : ()
                <img src="<%= global_data->{cdn} %>/<%= global_data->{dd} %>/img/champion/<%= $champ->{image} %>" class="img-rounded">
                <div><%= $champ->{name} %></div>
            </label>
        % }
    </div>
</div>

<div class="form-group">
    <label><h4>Authentication</h4></label>

    <div class="form-group">
        <label for="current_pw">
            Current password 
            % if( $pw_required ) {
                <strong>(required)</strong>
            % }
        </label>
        %= input_tag 'current_pw' => ( type => 'password', placeholder => 'Password', id => 'current_pw', class => 'form-control' )
    </div>

    <div class="form-group">
        <label for="new_pw_1">
            New password 
            % if( $pw_change_required ) {
                <strong>(Password change required!)</strong>
            % } else {
                (Leave empty if you do not want to change your password)
            % }
        </label>
        %= input_tag 'new_pw_1' => ( type => 'password', placeholder => 'Password', id => 'new_pw_1', class => 'form-control' )
    </div>

    <div class="form-group">
        <label for="new_pw_2">
            Retype new password
        </label>
        %= input_tag 'new_pw_2' => ( type => 'password', placeholder => 'Password', id => 'new_pw_2', class => 'form-control' )
    </div>
</div>

<button type="submit" class="btn">Save</button>

% end
%# of form


@@ championdb.html.ep

%= form_for url_for() => (method => 'POST') => begin
    <div class="form-group">
        <button type="submit" class="btn btn-default">Update DB from the Interwebs</button>
        <p class="help-block">You need to do this once per free champion rotation</p>
    </div>
% end

% if( $updated ) {
    % if( defined $errors ) {
        <div class="alert alert-danger" role="alert">
            % for my $error (@$errors) {
                <p><%= $error %></p>
            % }
        </div>
    % } else {
        <div class="alert alert-success" role="alert">
            Champion DB was updated without errors!
        </div>
    % }
% }

<table class="table table-hover table-condensed champion-table"><tbody>
    % for my $champ (@$champs) {
        <tr>
            <th> 
                <%= $champ->{name} %>
                % if( $champ->{free} ) {
                    <span class="label label-info">free</span>
                % }
            </th>
            % for my $role ( @$roles ) {
                <td>
                    % if( exists $champ->{roles}{$role} ) {
                        %= link_to exists $champ->{blacklist}{$role} ? 'no_blacklist' : 'blacklist' => { champion => $champ->{key}, role => $role } => begin
                            % if( exists $champ->{blacklist}{$role} ) {
                                <s><%= $role %></s>
                            % } else {
                                <%= $role %>
                            % }
                        % end
                    % } else {
                        %= link_to exists $champ->{whitelist}{$role} ? 'no_whitelist' : 'whitelist' => { champion => $champ->{key}, role => $role } => begin
                            % if( exists $champ->{whitelist}{$role} ) {
                                <u><%= $role %></u>
                            % } else {
                                <span class="non-role"><%= $role %></span>
                            % }
                        % end
                    % }
                </td>
            % }
        </tr>
    % }
</tbody></table>
