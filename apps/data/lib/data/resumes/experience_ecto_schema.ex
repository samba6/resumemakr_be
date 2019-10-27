defmodule Data.Resumes.Experience do
  use Ecto.Schema
  import Ecto.Changeset

  alias Data.Resumes.Resume
  alias Data.Resumes
  alias Data.Resumes.TextOnly

  @primary_key {:id, Ecto.ULID, autogenerate: true}
  @foreign_key_type Ecto.ULID
  schema "experiences" do
    belongs_to(:resume, Resume)
    field :company_name, :string
    field :from_date, :string
    field :position, :string
    field :to_date, :string
    field :index, :integer
    field :delete, :boolean, virtual: true

    has_many(
      :achievements,
      {"experience_achievements", TextOnly},
      foreign_key: :owner_id
    )
  end

  def changeset(%__MODULE__{} = schema, attrs \\ %{}) do
    schema
    |> cast(attrs, [
      :resume_id,
      :position,
      :company_name,
      :from_date,
      :to_date,
      :delete,
      :index
    ])
    |> assoc_constraint(:resume)
    |> Resumes.maybe_mark_for_deletion()
  end
end