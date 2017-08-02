# Publish/subscribe with PostgreSQL and Phoenix Framework

## Introduction

In our [previous experiment](https://github.com/bredikhin/phoenix-rethinkdb-elm-webpack-example#rephink-a-real-time-stack-based-on-phoenix-framework-rethinkdb-elm-webpack)
we looked at a way to build a naturally scalable real-time application using
[Phoenix Framework](http://www.phoenixframework.org),
[RethinkDB](http://rethinkdb.com) and [Elm](http://elm-lang.org). Turned out
RethinkDB makes going real-time quite simple and relatively painless. However,
an interesting question occurred as a follow-up to that article: can we do the
same with PostgreSQL? The short answer is yes, we can. But is it that simple?
Well, let's see it for ourselves.

## Fast-forward

Since we have already described the motivation behind these experiments with
the real-time applications based on Elixir, Phoenix and Elm, as well as the
setup process, in the
[original article](https://github.com/bredikhin/phoenix-rethinkdb-elm-webpack-example)
(which you should check for more in-depth instructions), we'll just go quickly
over the trivial parts of the setup here to reach the point where we can
discuss something new:

- create a new Phoenix project (we will be using v1.3 of the Phoenix Framework,
the last one at the moment of this writing): `mix phx.new pgsub && cd pgsub`;
- initialize Git repository: `git init`;
- get the dependencies: `mix deps.get`;
- make sure that PostgreSQL server is running: download your type of package
from [here](https://www.postgresql.org/download/) or just follow one of the
[guides](https://wiki.postgresql.org/wiki/Detailed_installation_guides) if
you haven't installed it yet;
- create the database: `mix ecto.create` (it will compile your application for
the first time as well);
- generate the repo / schema / migration: `mix phx.gen.schema Pgsub.Todo todos task:string completed:boolean`;
- migrate: `mix ecto.migrate`;
- remove Brunch.js: `rm assets/brunch-config.js`;
- add Webpack with loaders / plugins: `curl https://raw.githubusercontent.com/bredikhin/phoenix-rethinkdb-elm-webpack-example/master/assets/package.json > assets/package.json`;
- install npm dependencies: `cd assets && npm i && cd ..`;
- configure Webpack: `curl https://raw.githubusercontent.com/bredikhin/phoenix-rethinkdb-elm-webpack-example/master/assets/webpack.config.js > assets/webpack.config.js`;
- edit `config/dev.exs`, replace the watchers line with the following: `watchers: [npm: ["run", "watch", cd: Path.expand("../assets", __DIR__)]]`;
- add the frontend Elm app: `git remote add example git@github.com:bredikhin/phoenix-rethinkdb-elm-webpack-example.git && git fetch example && git checkout example/master elm`;
- get Elm dependencies: `cd elm && elm package install -y && cd ..`;
- switch the CSS file: `git checkout example/master assets/css/app.css`;
- clean up the page template in `lib/pgsub_web/templates/layout/app.html.eex`:
```
...
  <body>
    <script src="<%= static_path(@conn, "/js/app.js") %>"></script>
  </body>
...
```
- initialize the Elm application in `assets/js/app.js`:
```
// Elm application
let Elm = require('../../elm/Todo.elm')
let todomvc = Elm.Todo.fullscreen()
```
- create a channel: `mix phx.gen.channel Todo`;
- add your channel to the socket handler in `lib/pgsub_web/channels/user_socket.ex`:
`channel "todo:*", PgsubWeb.TodoChannel`.

## Ecto and channel broadcasting

Now that we are done with the common part of the setup, let's see how to handle
messages from our client on the server side. Let's replace the content of
`lib/pgsub_web/channels/todo_channel.ex` with the following:
```
defmodule PgsubWeb.TodoChannel do
  use PgsubWeb, :channel
  alias Pgsub.Pgsub.Todo
  alias Pgsub.Repo

  def join("todo:list", payload, socket) do
    if authorized?(payload) do
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def handle_in("todos", _payload, socket) do
    broadcast_all_to!(socket)

    {:noreply, socket}
  end

  def handle_in("insert", %{"todo" => data}, socket) do
    %Todo{}
    |> Todo.changeset(data)
    |> Repo.insert!

    broadcast_all_to!(socket)

    {:noreply, socket}
  end

  def handle_in("update", %{"todo" => data}, socket) do
    Todo
    |> Repo.get(data["id"])
    |> Todo.changeset(data)
    |> Repo.update!

    broadcast_all_to!(socket)

    {:noreply, socket}
  end

  def handle_in("delete", %{"todo" => data}, socket) do
    Todo
    |> Repo.get(data["id"])
    |> Repo.delete!

    broadcast_all_to!(socket)

    {:noreply, socket}
  end

  defp authorized?(_payload) do
    true
  end

  defp broadcast_all_to!(socket) do
    todos = Todo |> Repo.all
    PgsubWWeb.Endpoint.broadcast!(socket.topic, "todos", %{todos: todos})
  end
end
```

We also need to add the following encoder implementation to
`lib/pgsub/pgsub/todo.ex`:
```
defimpl Poison.Encoder, for: Pgsub.Pgsub.Todo do
  def encode(%{__struct__: _} = struct, options) do
    map = struct
          |> Map.from_struct
          |> Map.drop([:__meta__, :__struct__])
    Poison.Encoder.Map.encode(map, options)
  end
end
```
This piece, essentially, strips our `Todo` structure from the meta fields
(`__meta__`, `__struct__`) to help `Poison` encode it properly, so we could
send it over the wire.

It's all looking slightly different from
[the RethinkDB example](https://github.com/bredikhin/phoenix-rethinkdb-elm-webpack-example/blob/0ee47fdbcc8db93c9e2f909cd6d7e6c56c9ac699/lib/rephink/web/channels/todo_channel.ex),
but the good news is that thanks to the power of Ecto the code we just wrote
will work with a great number of database engines having Ecto adapters. Isn't
it amazing?

What's good as well is that if you start your Phoenix server based on this
channel code and open http://localhost:4000/ in two browser tabs, you'll see
that the changes you make in one tab get the other one instantly updated. So,
does it mean we have reached our initial goal?

Well, not exactly, since these real-time updates are based on the fact that we
have a single Phoenix server acting as a hub for all our changes and having all
the clients listening to the same topic. Obviously, this will not work, for
example, once we get multiple users subscribed to their own topics and
(partially) common data, or if we get some data changes coming from a different
application, etc.

But we can fix it easily. And here's where the database real-time tools come
into play. In this case, we'll be leveraging PostgreSQL's publish-subscribe
features.

## LISTEN / NOTIFY

PostgreSQL, among its other features, has a built-in publish-subscribe
functionality in the form of
[NOTIFY](https://www.postgresql.org/docs/current/static/sql-notify.html),
[LISTEN](https://www.postgresql.org/docs/current/static/sql-listen.html) (and,
well,
[UNLISTEN](https://www.postgresql.org/docs/current/static/sql-unlisten.html))
commands. Since you can easily read about each of those in the
[official documentation](https://www.postgresql.org/docs/current/static/index.html),
let's just dive in and continue with our example, uncovering the details about
those commands as we go.

First, in order to get notified about some specific changes in the database
(described by a trigger), let's create a trigger handler in PostgreSQL.
Connect to your database (which would be named `pgsub_dev` by default) with some
kind of a query tool
(e.g. [`psql`](https://www.postgresql.org/docs/current/static/app-psql.html),
you'd have to start it with something like `psql -d pgsub_dev -w`, or you can
use some kind of GUI as well, [pgAdmin](https://www.pgadmin.org), for example).
Run the following:
```
CREATE OR REPLACE FUNCTION notify_todos_changes()
RETURNS trigger AS $$
DECLARE
  current_row RECORD;
BEGIN
  IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
    current_row := NEW;
  ELSE
    current_row := OLD;
  END IF;
  PERFORM pg_notify(
    'todos_changes',
    json_build_object(
      'table', TG_TABLE_NAME,
      'type', TG_OP,
      'id', current_row.id,
      'data', row_to_json(current_row)
    )::text
  );
  RETURN current_row;
END;
$$ LANGUAGE plpgsql;
```
What is happening here is that we are building a JSON-encoded modification
report and are sending it as a notification using `pg_notify` function which
also takes a channel name (where "a channel" is just a way of separating the
notifications, not related to
[Phoenix channels](http://www.phoenixframework.org/docs/channels)),
`todos_changes` in our case. Note that depending on the SQL command which
triggered the notification, we either use the modified (`NEW`) row data in case
of `INSERT` / `UPDATE` or the original (`OLD`) one in case of `DELETE`.

Next, let's add the trigger itself:
```
CREATE TRIGGER notify_todos_changes_trg
AFTER INSERT OR UPDATE OR DELETE
ON todos
FOR EACH ROW
EXECUTE PROCEDURE notify_todos_changes();
```
Here we're asking Postgres to run our previously created `notify_todos_changes`
handler whenever any `INSERT`, `UPDATE` or `DELETE` on `todos` table is
performed.

And that is it, that's all the setup you need to have on the database side. You
can even try it out via `psql` and make sure it works: start your Phoenix server,
perform some updates via your application and run `LISTEN todos_changes;`. You
should see notifications coming in right away.

## Handling Postgres notifications within your Phoenix application

Now that the database setup has been taken care of, the only thing that's left
to do is to handle those notifications coming from PostgreSQL on the Phoenix
side.

Let's start with creating our notification handling module in
`lib/pgsub/notifications.ex`:
```
defmodule Pgsub.Notifications do
  use GenServer
  alias Pgsub.{Pgsub.Todo, Repo}

  import Poison, only: [decode!: 1]

  def start_link(channel) do
    GenServer.start_link(__MODULE__, channel)
  end

  def init(channel) do
    {:ok, pid} = Application.get_env(:pgsub, Pgsub.Repo)
      |> Postgrex.Notifications.start_link()
    ref = Postgrex.Notifications.listen!(pid, channel)

    data = Todo |> Repo.all

    {:ok, {pid, ref, channel, data}}
  end

  @topic "todo:list"

  def handle_info({:notification, pid, ref, "todos_changes", payload}, {pid, ref, channel, data}) do
    %{
      "data" => raw,
      "id" => id,
      "table" => "todos",
      "type" => type
    } = decode!(payload)
    row = for {k, v} <- raw, into: %{}, do: {String.to_atom(k), v}
    updated_data = case type do
      "UPDATE" -> Enum.map(data, fn x -> if x.id === id do Map.merge(x, row) else x end end)
      "INSERT" -> data ++ [struct(Todo, row)]
      "DELETE" -> Enum.filter(data,  &(&1.id !== id))
    end

    PgsubWeb.Endpoint.broadcast!(@topic, "todos", %{todos: updated_data})

    {:noreply, {pid, ref, channel, updated_data}}
  end
end
```
Note that the module itself is just a `GenServer` holding all the records in
its state, updating them whenever it gets a notification from the database
and broadcasting the updated data. Also, `channel` here is, once again, a
Postgres notification channel, not related to Phoenix channels we're using
to communicate between Elm and our server. Finally, don't forget to add a
corresponding worker to the main supervision tree in `lib/pgsub/application.ex`:
```
worker(Pgsub.Notifications, ["todos_changes"], id: :todos_changes),
```

Essentially, that is it. If we start our Phoenix server now, we should be
getting real-time updates to our application whenever the content of the
database table changes. However, some of those may be hitting our Elm frontend
twice, since in our channel module we still have some code that reads and
broadcasts current list of entries every time it gets updated via the
application itself. Let's remove it (putting the complete listing here for
sake of simplicity):
```
defmodule PgsubWeb.TodoChannel do
  use PgsubWeb, :channel
  alias Pgsub.{Pgsub.Todo, Repo}

  def join("todo:list", payload, socket) do
    if authorized?(payload) do
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def handle_in("todos", _payload, socket) do
    todos = Todo |> Repo.all
    PgsubWeb.Endpoint.broadcast!(socket.topic, "todos", %{todos: todos})

    {:noreply, socket}
  end

  def handle_in("insert", %{"todo" => data}, socket) do
    %Todo{}
    |> Todo.changeset(data)
    |> Repo.insert!

    {:noreply, socket}
  end

  def handle_in("update", %{"todo" => data}, socket) do
    Todo
    |> Repo.get(data["id"])
    |> Todo.changeset(data)
    |> Repo.update!

    {:noreply, socket}
  end

  def handle_in("delete", %{"todo" => data}, socket) do
    Todo
    |> Repo.get(data["id"])
    |> Repo.delete!

    {:noreply, socket}
  end

  defp authorized?(_payload) do
    true
  end
end
```

## Conclusion: RethinkDB vs PostgreSQL for real-time applications

So, what we managed to do here is to implement the same real-time example
functionality with PostgreSQL as we
[had previously implemented](https://github.com/bredikhin/phoenix-rethinkdb-elm-webpack-example)
using RethinkDB. Does it mean these two databases are completely
interchangeable when it comes to building real-time applications? It
obviously does not. Then which one should we use over another? Given the
fact that our example is very basic and no benchmarking whatsoever is
provided, I just can't advise you for or against any of these two. Let's,
however, look at the facts:

- PostgreSQL and RethinkDB are really different in its core: the first is a
rather traditional relational database, the second is a NoSQL one, and there
are plenty of valid reasons NoSQL / dynamic schema databases exist; some
people can say a good RDBMS like Postgres can easily be used instead of a
NoSQL one in most of use cases, others can argue that "schemaless" databases
are the future of data storage, but the truth still is that we shouldn't run
to extremes, since every task requires choosing appropriate database engine
based on its specifics, and there's no universal solution here;
- in terms of development, the approaches to the real-time functionality
these two databases take are somewhat different: LISTEN / NOTIFY / TRIGGER
mechanism is more low-level, whereas changefeeds give you in a certain sense
more flexibility while designing and developing your application;
- finally, yes, Postgres is mature and reliable, it has a solid production
record and is backed by an experienced community with an impressive list of
sponsors, but maybe the fact that RethinkDB is relatively young is not such
a bad thing: with Linux Foundation behind it, let's give it a few years, and
I'm sure it will be totally capable to compete against Postgres on some levels.

Anyway, even though the above example is heavily simplified and the
description lacks any metrics and / or benchmarks, I hope that I at least
got you interested, that you had fun and possibly learned something new.
And, as usually, constructive feedback is welcome.

## Credits

- https://github.com/bredikhin/phoenix-rethinkdb-elm-webpack-example
- http://www.phoenixframework.org
- http://elm-lang.org
- https://webpack.js.org
- https://github.com/evancz/elm-todomvc
- https://medium.com/@kaisersly/postgrex-notifications-759574f5796e
- http://blog.sagemath.com/2017/02/09/rethinkdb-vs-postgres.html

## License

[The MIT License](http://opensource.org/licenses/MIT)

Copyright (c) 2017 [Ruslan Bredikhin](http://ruslanbredikhin.com/)
