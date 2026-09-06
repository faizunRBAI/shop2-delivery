# ---------------------------------------------------------------------------
# Container registry for the ShopFast application image.
# Tags are IMMUTABLE: a git SHA tag can never be repointed at different bytes,
# which is what makes the GitOps image reference trustworthy.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "shopfast" {
  name                 = "${var.project_name}/shopfast"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${var.project_name}-shopfast"
  }
}

resource "aws_ecr_lifecycle_policy" "shopfast" {
  repository = aws_ecr_repository.shopfast.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the 30 most recent images; expire older ones."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
