class AddActivatedToOrganizations < ActiveRecord::Migration[5.0]
  def change
    add_column :organizations, :activated, :boolean, default: true
  end
end
