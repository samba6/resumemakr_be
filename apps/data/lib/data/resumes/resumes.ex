defmodule Data.Resumes do
  @moduledoc """
  The Resume context.
  """

  import Ecto.Query, warn: false
  alias Data.Repo
  alias Data.Resumes.PersonalInfo
  alias Data.Resumes.Resume
  alias Data.Resumes.Experience
  alias Data.Resumes.Education
  alias Ecto.Changeset

  @pattern_integer_id ~r/^\d+$/

  @already_uploaded "___ALREADY_UPLOADED___"

  @doc """
  Returns the list of resumes for a user.

  ## Examples

      iex> list_resumes(12345)
      [%Resume{}, ...]

  """

  def list_resumes(user_id) do
    Resume
    |> where([r], r.user_id == ^user_id)
    |> Repo.all()
  end

  @spec list_resumes(any(), %{
          after: nil | integer(),
          before: nil | integer(),
          first: nil | integer(),
          last: nil | integer()
        }) ::
          {:error, <<_::64, _::_*8>>}
          | {:ok,
             %{
               edges: [map()],
               page_info: %{
                 end_cursor: binary(),
                 has_next_page: boolean(),
                 has_previous_page: boolean(),
                 start_cursor: binary()
               }
             }}
  def list_resumes(user_id, pagination_args) do
    Resume
    |> where([r], r.user_id == ^user_id)
    |> Absinthe.Relay.Connection.from_query(&Repo.all/1, pagination_args)
  end

  @doc """
  Gets a single Resume.

  Raises `Ecto.NoResultsError` if the Resume does not exist.

  ## Examples

      iex> get_resume!(123)
      %Resume{}

      iex> get_resume!(456)
      ** (Ecto.NoResultsError)

  """
  def get_resume(id), do: Repo.get(Resume, id)

  def get_resume_by(attrs) do
    Repo.get_by(Resume, attrs)
  end

  @doc """
  Creates a Resume.

  ## Examples

      iex> create_resume_full(%{field: value})
      {:ok, %Resume{}}

      iex> create_resume_full(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_resume(attrs) do
    %Resume{}
    |> Resume.changeset(
      attrs
      |> unique_title()
    )
    |> Repo.insert()
  end

  defp unique_title(%{title: nil} = attrs), do: attrs

  defp unique_title(%{title: title, user_id: user_id} = attrs) do
    case get_resume_by(title: title, user_id: user_id) do
      nil ->
        attrs

      _ ->
        Map.put(attrs, :title, "#{title}_#{System.os_time(:seconds)}")
    end
  end

  defp unique_title(attrs), do: attrs

  @doc """
  Updates a Resume.

  ## Examples

      iex> update_resume(Resume, %{field: new_value})
      {:ok, %Resume{}}

      iex> update_resume(Resume, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_resume(%Resume{} = resume, %{} = attrs) do
    {resume, attrs} =
      resume
      |> Repo.preload(Resume.assoc_fields())
      |> augment_attrs(attrs)

    resume
    |> Resume.changeset(attrs)
    |> Repo.update()
  end

  @doc ~S"""
    If the update attributes are missing fields from the original
    resume, them we copy the missing fields from the resume retrieved
    from the database into the update attributes.

    The reason for this is because we are using
    Ecto.Changeset.cast_assoc which will raise by default if there are
    missing associations
  """
  @spec augment_attrs(Resume.t(), map()) :: {Resume.t(), Map.t()}
  def augment_attrs(%Resume{} = resume, %{} = attrs) do
    augmented_attrs =
      resume
      |> Map.from_struct()
      |> Enum.reduce(%{}, fn
        {k, _}, acc when k in [:__meta__, :inserted_at, :updated_at] ->
          case Map.has_key?(attrs, k) do
            true ->
              Map.put(acc, k, attrs[k])

            _ ->
              acc
          end

        {k, %Ecto.Association.NotLoaded{}}, acc ->
          case Map.has_key?(attrs, k) do
            true ->
              Map.put(acc, k, attrs[k])

            _ ->
              acc
          end

        {:personal_info, v_db}, acc ->
          sanitize_assoc(:personal_info, v_db, acc, attrs)

        {key, v_db}, acc when key in [:education, :experiences, :skills] ->
          sanitize_assoc(key, v_db, acc, attrs)

        {:hobbies, _}, acc ->
          Map.put(acc, :hobbies, attrs[:hobbies])

        {k, v_db}, acc when is_map(v_db) or is_list(v_db) ->
          case Map.has_key?(attrs, k) do
            true ->
              update_if_missing(k, v_db, acc, attrs[k])

            _ ->
              cond do
                is_map(v_db) ->
                  Map.put(acc, k, Map.from_struct(v_db))

                is_list(v_db) ->
                  Map.put(acc, k, Enum.map(v_db, &Map.from_struct/1))

                true ->
                  Map.put(acc, k, v_db)
              end
          end

        {k, v}, acc ->
          case Map.has_key?(attrs, k) do
            true ->
              Map.put(acc, k, attrs[k])

            _ ->
              Map.put(acc, k, v)
          end
      end)
      |> sanitize_personal_info()

    {resume, augmented_attrs}
  end

  defp sanitize_assoc(key, v_db, acc, attrs) when v_db == nil or v_db == [] do
    update_if_key(key, acc, attrs)
  end

  defp sanitize_assoc(:personal_info, v_db, acc, attrs) do
    case Map.get(attrs, :personal_info, :ok) do
      :ok ->
        acc

      nil ->
        Map.put(
          acc,
          :personal_info,
          mark_for_deletion(v_db)
        )

      v_user ->
        # we assume user is trying to update/delete
        Map.put(
          acc,
          :personal_info,
          Map.put(v_user, :id, v_db.id)
        )
    end
  end

  defp sanitize_assoc(key, v_dbs, acc, attrs) do
    case Map.get(attrs, key, :ok) do
      :ok ->
        acc

      v_user when v_user == nil or v_user == [nil] ->
        Map.put(
          acc,
          key,
          Enum.map(v_dbs, &mark_for_deletion/1)
        )

      v_user ->
        {with_ids, no_ids} =
          Enum.reduce(v_user, {%{}, []}, fn assoc, {with_ids, no_ids} ->
            case Map.has_key?(assoc, :id) do
              true ->
                {Map.put(with_ids, to_string(assoc.id), assoc), no_ids}

              _ ->
                {with_ids, [assoc | no_ids]}
            end
          end)

        updates =
          Enum.reduce(v_dbs, [], fn assoc, acc ->
            id = to_string(assoc.id)

            case with_ids[id] do
              nil ->
                [mark_for_deletion(assoc) | acc]

              update_assoc ->
                [update_assoc | acc]
            end
          end)
          |> Enum.concat(no_ids)

        Map.put(acc, key, updates)
    end
  end

  defp update_if_key(key, acc, attrs) do
    case Map.has_key?(attrs, key) do
      true ->
        Map.put(acc, key, attrs[key])

      _ ->
        acc
    end
  end

  defp mark_for_deletion(schema) do
    schema |> Map.from_struct() |> Map.put(:delete, true)
  end

  defp update_if_missing(k, %{} = v_db, acc, nil),
    do: Map.put(acc, k, Map.from_struct(v_db))

  defp update_if_missing(_k, [], acc, nil), do: acc

  defp update_if_missing(k, v_db, acc, %{} = v_user) do
    if atom_keys?(v_user) do
      case v_user[:id] do
        nil ->
          Map.put(acc, k, Map.put(v_user, :id, v_db.id))

        _ ->
          Map.put(acc, k, v_user)
      end
    else
      case v_user["id"] do
        nil ->
          Map.put(acc, k, Map.put(v_user, "id", v_db.id))

        _ ->
          Map.put(acc, k, v_user)
      end
    end
  end

  defp update_if_missing(k, v_dbs, acc, nil),
    do: Map.put(acc, k, Enum.map(v_dbs, &Map.from_struct/1))

  defp update_if_missing(k, v_dbs, acc, v_users) do
    v_dbs = Enum.map(v_dbs, &Map.from_struct/1)

    v_users
    |> Enum.map(&(&1[:id] || &1["id"]))
    |> Enum.reject(&(&1 == nil))
    |> Enum.map(fn id ->
      str_id = "#{id}"

      case Regex.match?(@pattern_integer_id, str_id) do
        true ->
          String.to_integer(str_id)

        _ ->
          str_id
      end
    end)
    |> case do
      [] ->
        Map.put(acc, k, Enum.concat(v_dbs, v_users))

      user_data_ids ->
        in_db_not_in_user_data =
          v_dbs
          |> Enum.reject(&Enum.member?(user_data_ids, &1.id))
          |> Enum.map(&Map.from_struct/1)

        Map.put(acc, k, Enum.concat(in_db_not_in_user_data, v_users))
    end
  end

  defp sanitize_personal_info(attrs) do
    cond do
      Map.has_key?(attrs, :personal_info) ->
        update_in(attrs.personal_info, &to_string_photo_path/1)

      Map.has_key?(attrs, "personal_info") ->
        update_in(attrs["personal_info"], &to_string_photo_path/1)

      true ->
        attrs
    end
  end

  defp to_string_photo_path(personal_info) when personal_info == nil or personal_info == %{} do
    personal_info
  end

  defp to_string_photo_path(personal_info) do
    case personal_info[:photo] || personal_info["photo"] do
      @already_uploaded ->
        Map.drop(personal_info, [:photo, "photo"])

      %{file_name: _} ->
        Map.drop(personal_info, [:photo, "photo"])

      _ ->
        personal_info
    end
  end

  defp atom_keys?(map) do
    Enum.reduce(map, true, fn {k, _}, acc ->
      acc && is_atom(k)
    end)
  end

  @doc """
  Deletes a Resume.

  ## Examples

      iex> delete_resume(Resume)
      {:ok, %Resume{}}

      iex> delete_resume(Resume)
      {:error, %Ecto.Changeset{}}

  """
  def delete_resume(%Resume{} = resume) do
    Repo.delete(resume)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking Resume changes.

  ## Examples

      iex> change_resume(Resume)
      %Ecto.Changeset{source: %Resume{}}

  """
  def change_resume(%Resume{} = resume) do
    Resume.changeset(resume, %{})
  end

  @doc """
  Returns the list of personal_info.

  ## Examples

      iex> list_personal_info()
      [%PersonalInfo{}, ...]

  """
  def list_personal_info do
    Repo.all(PersonalInfo)
  end

  @doc """
  Gets a single personal_info.

  Raises `Ecto.NoResultsError` if the Personal info does not exist.

  ## Examples

      iex> get_personal_info!(123)
      %PersonalInfo{}

      iex> get_personal_info!(456)
      ** (Ecto.NoResultsError)

  """
  def get_personal_info!(id), do: Repo.get!(PersonalInfo, id)

  @doc """
  Updates a personal_info.

  ## Examples

      iex> update_personal_info(personal_info, %{field: new_value})
      {:ok, %PersonalInfo{}}

      iex> update_personal_info(personal_info, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_personal_info(%PersonalInfo{} = personal_info, attrs) do
    personal_info
    |> PersonalInfo.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a PersonalInfo.

  ## Examples

      iex> delete_personal_info(personal_info)
      {:ok, %PersonalInfo{}}

      iex> delete_personal_info(personal_info)
      {:error, %Ecto.Changeset{}}

  """
  def delete_personal_info(%PersonalInfo{} = personal_info) do
    Repo.delete(personal_info)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking personal_info changes.

  ## Examples

      iex> change_personal_info(personal_info)
      %Ecto.Changeset{source: %PersonalInfo{}}

  """
  def change_personal_info(%PersonalInfo{} = personal_info) do
    PersonalInfo.changeset(personal_info, %{})
  end

  @doc """
  Returns the list of experiences.

  ## Examples

      iex> list_experiences()
      [%Experience{}, ...]

  """
  def list_experiences do
    Repo.all(Experience)
  end

  @doc """
  Gets a single experience.

  Raises `Ecto.NoResultsError` if the Experience does not exist.

  ## Examples

      iex> get_experience!(123)
      %Experience{}

      iex> get_experience!(456)
      ** (Ecto.NoResultsError)

  """
  def get_experience!(id), do: Repo.get!(Experience, id)

  @doc """
  Updates a experience.

  ## Examples

      iex> update_experience(experience, %{field: new_value})
      {:ok, %Experience{}}

      iex> update_experience(experience, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_experience(%Experience{} = experience, attrs) do
    experience
    |> Experience.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Experience.

  ## Examples

      iex> delete_experience(experience)
      {:ok, %Experience{}}

      iex> delete_experience(experience)
      {:error, %Ecto.Changeset{}}

  """
  def delete_experience(%Experience{} = experience) do
    Repo.delete(experience)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking experience changes.

  ## Examples

      iex> change_experience(experience)
      %Ecto.Changeset{source: %Experience{}}

  """
  def change_experience(%Experience{} = experience) do
    Experience.changeset(experience, %{})
  end

  ################################# EDUCATION #################################

  @doc """
  Returns the list of education.

  ## Examples

      iex> list_education()
      [%Education{}, ...]

  """
  def list_education do
    Repo.all(Education)
  end

  @doc """
  Gets a single education.

  Raises `Ecto.NoResultsError` if the Education does not exist.

  ## Examples

      iex> get_education!(123)
      %Education{}

      iex> get_education!(456)
      ** (Ecto.NoResultsError)

  """
  def get_education!(id), do: Repo.get!(Education, id)

  @doc """
  Creates a education.

  ## Examples

      iex> create_education(%{field: value})
      {:ok, %Education{}}

      iex> create_education(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_education(attrs \\ %{}) do
    %Education{}
    |> Education.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a education.

  ## Examples

      iex> update_education(education, %{field: new_value})
      {:ok, %Education{}}

      iex> update_education(education, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_education(%Education{} = education, attrs) do
    education
    |> Education.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Education.

  ## Examples

      iex> delete_education(education)
      {:ok, %Education{}}

      iex> delete_education(education)
      {:error, %Ecto.Changeset{}}

  """
  def delete_education(%Education{} = education) do
    Repo.delete(education)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking education changes.

  ## Examples

      iex> change_education(education)
      %Ecto.Changeset{source: %Education{}}

  """
  def change_education(%Education{} = education) do
    Education.changeset(education, %{})
  end

  alias Data.Resumes.Skill

  @doc """
  Returns the list of skills.

  ## Examples

      iex> list_skills()
      [%Skill{}, ...]

  """
  def list_skills do
    Repo.all(Skill)
  end

  @doc """
  Gets a single skill.

  Raises `Ecto.NoResultsError` if the Skill does not exist.

  ## Examples

      iex> get_skill!(123)
      %Skill{}

      iex> get_skill!(456)
      ** (Ecto.NoResultsError)

  """
  def get_skill!(id), do: Repo.get!(Skill, id)

  @doc """
  Creates a skill.

  ## Examples

      iex> create_skill(%{field: value})
      {:ok, %Skill{}}

      iex> create_skill(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_skill(attrs \\ %{}) do
    %Skill{}
    |> Skill.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a skill.

  ## Examples

      iex> update_skill(skill, %{field: new_value})
      {:ok, %Skill{}}

      iex> update_skill(skill, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_skill(%Skill{} = skill, attrs) do
    skill
    |> Skill.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Skill.

  ## Examples

      iex> delete_skill(skill)
      {:ok, %Skill{}}

      iex> delete_skill(skill)
      {:error, %Ecto.Changeset{}}

  """
  def delete_skill(%Skill{} = skill) do
    Repo.delete(skill)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking skill changes.

  ## Examples

      iex> change_skill(skill)
      %Ecto.Changeset{source: %Skill{}}

  """
  def change_skill(%Skill{} = skill) do
    Skill.changeset(skill, %{})
  end

  @spec maybe_mark_for_deletion(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def maybe_mark_for_deletion(%Changeset{} = changeset) do
    if Changeset.get_change(changeset, :delete) do
      %Changeset{changeset | action: :delete, valid?: true, errors: []}
    else
      changeset
    end
  end

  def already_uploaded, do: @already_uploaded
end