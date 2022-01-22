# frozen_string_literal: true

RSpec.describe PgOnlineSchemaChange::Query do
  describe ".alter_statement?" do
    it "returns true" do
      query = "ALTER TABLE books ADD COLUMN \"purchased\" BOOLEAN DEFAULT FALSE;"
      expect(described_class.alter_statement?(query)).to eq(true)
    end

    it "returns false" do
      query = "CREATE DATABASE FOO"
      expect(described_class.alter_statement?(query)).to eq(false)
    end

    it "returns false when thrown Error" do
      query = "ALTER"
      expect(described_class.alter_statement?(query)).to eq(false)
    end

    it "returns true with multiple alter statements" do
      query = <<~SQL
        ALTER TABLE books ADD COLUMN \"purchased\" BOOLEAN DEFAULT FALSE;
        ALTER TABLE cards ADD COLUMN \"purchased\" BOOLEAN DEFAULT FALSE;
      SQL

      expect(described_class.alter_statement?(query)).to eq(true)
    end

    it "returns false with multiple statements and only one alter statement" do
      query = "ALTER TABLE books ADD COLUMN \"purchased\" BOOLEAN DEFAULT FALSE; CREATE DATABASE FOO;"
      expect(described_class.alter_statement?(query)).to eq(false)
    end
  end

  describe ".table" do
    it "returns the table name" do
      query = "ALTER TABLE books ADD COLUMN \"purchased\" BOOLEAN DEFAULT FALSE;"
      expect(described_class.table(query)).to eq("books")
    end

    it "returns the table name for rename statements" do
      query = "ALTER TABLE books RENAME COLUMN \"email\" to \"new_email\";"
      expect(described_class.table(query)).to eq("books")
    end
  end

  describe ".run" do
    it "runs the query and yields the result" do
      client = PgOnlineSchemaChange::Client.new(client_options)
      query = "SELECT 'FooBar' as result"

      expect(client.connection).to receive(:exec).with("BEGIN;").and_call_original
      expect(client.connection).to receive(:exec).with("SELECT 'FooBar' as result").and_call_original
      expect(client.connection).to receive(:exec).with("COMMIT;").and_call_original

      described_class.run(client.connection, query) do |result|
        expect(result.count).to eq(1)
        result.each do |row|
          expect(row).to eq({ "result" => "FooBar" })
        end
      end
    end
  end

  describe ".table_columns" do
    it "returns column names" do
      client = PgOnlineSchemaChange::Client.new(client_options)
      described_class.run(client.connection, new_dummy_table_sql)

      result = [
        { "column_name" => "user_id", "column_position" => 1, "type" => "integer" },
        { "column_name" => "username", "column_position" => 2,
          "type" => "character varying(50)" },
        { "column_name" => "password", "column_position" => 3,
          "type" => "character varying(50)" },
        { "column_name" => "email", "column_position" => 4, "type" => "character varying(255)" },
        { "column_name" => "created_on", "column_position" => 5,
          "type" => "timestamp without time zone" },
        { "column_name" => "last_login", "column_position" => 6,
          "type" => "timestamp without time zone" },
      ]

      expect(described_class.table_columns(client)).to eq(result)
    end
  end

  describe ".alter_statement_for" do
    it "returns alter statement for shadow table" do
      client = PgOnlineSchemaChange::Client.new(client_options)

      result = described_class.alter_statement_for(client, "new_books")
      expect(result).to eq("ALTER TABLE new_books ADD COLUMN purchased boolean DEFAULT false")
    end

    it "returns alter statement for shadow table when muliple queries are present" do
      query = <<~SQL
        ALTER TABLE books ADD COLUMN \"purchased\" BOOLEAN DEFAULT FALSE;
        ALTER TABLE cards ADD COLUMN \"purchased\" BOOLEAN DEFAULT FALSE;
      SQL

      options = client_options.to_h.merge(
        alter_statement: query,
      )
      client_options = Struct.new(*options.keys).new(*options.values)
      client = PgOnlineSchemaChange::Client.new(client_options)

      result = described_class.alter_statement_for(client, "new_books")
      expect(result).to eq("ALTER TABLE new_books ADD COLUMN purchased boolean DEFAULT false; ALTER TABLE new_books ADD COLUMN purchased boolean DEFAULT false")
    end

    it "returns alter statement for shadow table with RENAME" do
      options = client_options.to_h.merge(
        alter_statement: "ALTER TABLE books RENAME COLUMN \"email\" to \"new_email\";",
      )
      client_options = Struct.new(*options.keys).new(*options.values)
      client = PgOnlineSchemaChange::Client.new(client_options)

      result = described_class.alter_statement_for(client, "new_books")
      expect(result).to eq("ALTER TABLE new_books RENAME COLUMN email TO new_email")
    end

    it "returns alter statement for shadow table with DROP" do
      options = client_options.to_h.merge(
        alter_statement: "ALTER TABLE books DROP \"email\"",
      )
      client_options = Struct.new(*options.keys).new(*options.values)
      client = PgOnlineSchemaChange::Client.new(client_options)

      result = described_class.alter_statement_for(client, "new_books")
      expect(result).to eq("ALTER TABLE new_books DROP email")
    end
  end

  describe ".get_indexes_for" do
    it "returns index statements for the given table on client" do
      client = PgOnlineSchemaChange::Client.new(client_options)

      query = <<~SQL
        SELECT indexdef, schemaname
        FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = 'books'
      SQL

      expect(client.connection).to receive(:exec).with("BEGIN;").and_call_original
      expect(client.connection).to receive(:exec).with(query).and_call_original
      expect(client.connection).to receive(:exec).with("COMMIT;").and_call_original

      result = described_class.get_indexes_for(client, "books")
      expect(result).to eq([
                             "CREATE UNIQUE INDEX books_pkey ON books USING btree (user_id)",
                             "CREATE UNIQUE INDEX books_username_key ON books USING btree (username)",
                             "CREATE UNIQUE INDEX books_email_key ON books USING btree (email)",
                           ])
    end
  end

  describe ".get_updated_indexes_for" do
    it "returns index statements for shadow table with altered index name" do
      client = PgOnlineSchemaChange::Client.new(client_options)

      query = <<~SQL
        SELECT indexdef, schemaname
        FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = 'books'
      SQL

      expect(client.connection).to receive(:exec).with("BEGIN;").and_call_original
      expect(client.connection).to receive(:exec).with(query).and_call_original
      expect(client.connection).to receive(:exec).with("COMMIT;").and_call_original

      result = described_class.get_updated_indexes_for(client, "new_books", [], [])
      expect(result).to eq([
                             "CREATE UNIQUE INDEX books_pkey_pgosc ON public.new_books USING btree (user_id)",
                             "CREATE UNIQUE INDEX books_username_key_pgosc ON public.new_books USING btree (username)",
                             "CREATE UNIQUE INDEX books_email_key_pgosc ON public.new_books USING btree (email)",
                           ])
    end

    it "returns index statements for shadow table with altered index name and skips dropped columns" do
      client = PgOnlineSchemaChange::Client.new(client_options)

      query = <<~SQL
        SELECT indexdef, schemaname
        FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = 'books'
      SQL

      expect(client.connection).to receive(:exec).with("BEGIN;").and_call_original
      expect(client.connection).to receive(:exec).with(query).and_call_original
      expect(client.connection).to receive(:exec).with("COMMIT;").and_call_original

      result = described_class.get_updated_indexes_for(client, "new_books", ["email"], [])
      expect(result).to eq([
                             "CREATE UNIQUE INDEX books_pkey_pgosc ON public.new_books USING btree (user_id)",
                             "CREATE UNIQUE INDEX books_username_key_pgosc ON public.new_books USING btree (username)",
                           ])
    end

    it "returns index statements for shadow table with altered index name and handles renamed columns" do
      client = PgOnlineSchemaChange::Client.new(client_options)

      query = <<~SQL
        SELECT indexdef, schemaname
        FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = 'books'
      SQL

      expect(client.connection).to receive(:exec).with("BEGIN;").and_call_original
      expect(client.connection).to receive(:exec).with(query).and_call_original
      expect(client.connection).to receive(:exec).with("COMMIT;").and_call_original

      result = described_class.get_updated_indexes_for(client, "new_books", [],
                                                       [{ old_name: "email", new_name: "new_email" }])
      expect(result).to eq([
                             "CREATE UNIQUE INDEX books_pkey_pgosc ON public.new_books USING btree (user_id)",
                             "CREATE UNIQUE INDEX books_username_key_pgosc ON public.new_books USING btree (username)",
                             "CREATE UNIQUE INDEX books_email_key_pgosc ON public.new_books USING btree (new_email)",
                           ])
    end
  end

  describe ".primary_key_for" do
    let(:client) { PgOnlineSchemaChange::Client.new(client_options) }

    before do
      create_dummy_table(client)
    end

    it "returns index statements for shadow table with altered index name" do
      query = <<~SQL
        SELECT
          pg_attribute.attname as column_name
        FROM pg_index, pg_class, pg_attribute, pg_namespace
        WHERE
          pg_class.oid = \'#{client.table}\'::regclass AND
          indrelid = pg_class.oid AND
          nspname = \'#{client.schema}\' AND
          pg_class.relnamespace = pg_namespace.oid AND
          pg_attribute.attrelid = pg_class.oid AND
          pg_attribute.attnum = any(pg_index.indkey)
        AND indisprimary
      SQL

      expect(client.connection).to receive(:exec).with("BEGIN;").and_call_original
      expect(client.connection).to receive(:exec).with(query).and_call_original
      expect(client.connection).to receive(:exec).with("COMMIT;").and_call_original

      result = described_class.primary_key_for(client, client.table)
      expect(result).to eq("user_id")
    end
  end

  describe ".dropped_columns" do
    it "returns column being dropped" do
      options = client_options.to_h.merge(
        alter_statement: "ALTER TABLE books DROP \"email\";",
      )
      client_options = Struct.new(*options.keys).new(*options.values)
      client = PgOnlineSchemaChange::Client.new(client_options)

      result = described_class.dropped_columns(client)
      expect(result).to eq(["email"])
    end

    it "returns all columns being dropped" do
      options = client_options.to_h.merge(
        alter_statement: "ALTER TABLE books DROP \"email\";ALTER TABLE books DROP \"foobar\";",
      )
      client_options = Struct.new(*options.keys).new(*options.values)
      client = PgOnlineSchemaChange::Client.new(client_options)
      result = described_class.dropped_columns(client)
      expect(result).to eq(%w[email foobar])
    end

    it "returns no being dropped" do
      client = PgOnlineSchemaChange::Client.new(client_options)

      result = described_class.dropped_columns(client)
      expect(result).to eq([])
    end
  end

  describe ".renamed_columns" do
    it "returns column being renamed" do
      options = client_options.to_h.merge(
        alter_statement: "ALTER TABLE books RENAME COLUMN \"email\" to \"new_email\";",
      )
      client_options = Struct.new(*options.keys).new(*options.values)
      client = PgOnlineSchemaChange::Client.new(client_options)

      result = described_class.renamed_columns(client)
      expect(result).to eq([
                             {
                               old_name: "email",
                               new_name: "new_email",
                             },
                           ])
    end

    it "returns all columns being renamed" do
      options = client_options.to_h.merge(
        alter_statement: "ALTER TABLE books RENAME COLUMN \"email\" to \"new_email\";ALTER TABLE books RENAME COLUMN \"foobar\" to \"new_foobar\";",
      )
      client_options = Struct.new(*options.keys).new(*options.values)
      client = PgOnlineSchemaChange::Client.new(client_options)
      result = described_class.renamed_columns(client)
      expect(result).to eq([
                             {
                               old_name: "email",
                               new_name: "new_email",
                             },
                             {
                               old_name: "foobar",
                               new_name: "new_foobar",
                             },
                           ])
    end

    it "returns no being renamed" do
      client = PgOnlineSchemaChange::Client.new(client_options)

      result = described_class.renamed_columns(client)
      expect(result).to eq([])
    end
  end
end
