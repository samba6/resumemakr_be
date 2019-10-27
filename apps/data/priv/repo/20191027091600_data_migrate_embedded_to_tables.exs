defmodule Data.Repo.Migrations.DataMigrateLanguagesToSpoken do
  import Ecto.Query
  alias Data.Repo

  defp get_languages_from_resumes do
    from(
      r in "resumes",
      select: %{
        id: r.id,
        languages: r.languages,
        inserted_at: r.inserted_at,
        updated_at: r.updated_at
      }
    )
    |> compute_insertable_ratables(:languages)
  end

  defp get_additional_skills_from_resumes do
    from(
      r in "resumes",
      select: %{
        id: r.id,
        additional_skills: r.additional_skills,
        inserted_at: r.inserted_at,
        updated_at: r.updated_at
      }
    )
    |> compute_insertable_ratables(:additional_skills)
  end

  defp compute_insertable_ratables(
         embedded_from_resumes_query,
         embedded_column
       ) do
    embedded_from_resumes_query
    |> Repo.all()
    |> Enum.flat_map(fn resume ->
      (resume[embedded_column] || [])
      |> Enum.sort(&(&1["index"] <= &2["index"]))
      |> Enum.map(fn ratable ->
        Map.take(ratable, ["description", "level"])
        |> Map.merge(%{
          "resume_id" => resume.id,
          "inserted_at" => resume.inserted_at,
          "updated_at" => resume.updated_at,
          "id" => Ecto.ULID.bingenerate()
        })
      end)
    end)
  end

  def migrate_to_embedded(table, embedded_column) do
    from(
      s in table,
      select: %{
        id: s.id,
        description: s.description,
        level: s.level,
        resume_id: s.resume_id
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.resume_id)
    |> Enum.map(fn {resume_id, table_values} ->
      embedded_values =
        Enum.with_index(table_values, 1)
        |> Enum.map(fn {spoken, index} ->
          spoken
          |> Map.take([:description, :level])
          |> Map.merge(%{
            index: index,
            id: Ecto.UUID.cast!(spoken.id)
          })
        end)

      update_values = [
        {embedded_column, embedded_values}
      ]

      from(
        r in "resumes",
        where: r.id == ^resume_id,
        update: [
          set: ^update_values
        ]
      )
      |> Repo.update_all([])
    end)
  end

  def migrate_to_tables do
    Repo.insert_all("spoken_languages", get_languages_from_resumes())
    Repo.insert_all("supplementary_skills", get_additional_skills_from_resumes())
  end
end