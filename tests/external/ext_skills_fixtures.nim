## The files of the specification's own example (ext-skills@167da6c, skills.mdx,
## "Example Message Flow"), shared by the skills tests.

const
  SkillMd* = "---\nname: pdf-processing\ndescription: Extract, fill, and assemble PDF documents\n---\n\n# PDF processing\n\nChoose the matching template from `templates/`.\n"
  Invoice* = "# Invoice\n\nCustomer:\nAmount:\n"
  PurchaseOrder* = "# Purchase order\n\nSupplier:\nItems:\n"

const
  CreditNote* = "# Credit note\n\nInvoice:\nCredit amount:\n"
  GitMd* = "---\nname: git-workflow\ndescription: Follow this team's Git conventions\n---\n\nUse branches.\n"
