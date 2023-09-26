---
title: "AWS SAM Pipelineを使ってCI/CDを実現する"
emoji: "🛠️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - "aws"
  - "awssam"
  - "cicd"
  - "githubactions"
published: true
published_at: "2023-09-26 08:00"
publication_name: "fusic"
---

AWSでサーバーレスなシステムを簡単に構築する方法の一つとしてAWS SAMがあります。
AWS SAMには、作ったシステムのCI/CDを簡単に構築する方法の1つとして、AWS SAM Pipelinesがあります。

https://aws.amazon.com/jp/blogs/compute/introducing-aws-sam-pipelines-automatically-generate-deployment-pipelines-for-serverless-applications/

これを使うと本来複雑な手順を経て構築するCI/CDを、簡単に構築することができます。CI/CDの実行先はAWS CodePipelineはもちろん、Jenkins, GitLab CI/CD, GitHub Actions, Bitbucket Pipelinesから選択が可能です。

本記事ではGitHub Actionsを使ったCI/CDの構築手順やハマりやすいポイントをまとめます。手順通りに実行するとGitHub Actions上でこのようなCI/CDパイプラインが構築されます。

![](https://storage.googleapis.com/zenn-user-upload/571a23313a84-20230926.png)

## 事前準備

### AWS SAM CLIのインストール

最新版のAWS SAM CLIをインストールします。macOSをお使いの場合、2023年9月以降はHomebrewインストーラのメンテナンスが行われなくなっているのでご注意ください。詳細なインストール手順は以下ドキュメントを参照してください。

https://docs.aws.amazon.com/ja_jp/serverless-application-model/latest/developerguide/install-sam-cli.html

### サンプルプロジェクトの作成

CI/CDを構築するためのサンプルプロジェクトを構築します。以下のコマンドを実行ください。

```sh
$ sam init

You can preselect a particular runtime or package type when using the `sam init` experience.
Call `sam init --help` to learn more.

Which template source would you like to use?
	1 - AWS Quick Start Templates
	2 - Custom Template Location
Choice: 1

Choose an AWS Quick Start application template
	1 - Hello World Example
	2 - Data processing
	3 - Hello World Example with Powertools for AWS Lambda
	4 - Multi-step workflow
	5 - Scheduled task
	6 - Standalone function
	7 - Serverless API
	8 - Infrastructure event management
	9 - Lambda Response Streaming
	10 - Serverless Connector Hello World Example
	11 - Multi-step workflow with Connectors
	12 - GraphQLApi Hello World Example
	13 - Full Stack
	14 - Lambda EFS example
	15 - Hello World Example With Powertools for AWS Lambda
	16 - DynamoDB Example
	17 - Machine Learning
Template: 1

Use the most popular runtime and package type? (Python and zip) [y/N]: n

Which runtime would you like to use?
	1 - aot.dotnet7 (provided.al2)
	2 - dotnet6
	3 - go1.x
	4 - go (provided.al2)
	5 - graalvm.java11 (provided.al2)
	6 - graalvm.java17 (provided.al2)
	7 - java17
	8 - java11
	9 - java8.al2
	10 - java8
	11 - nodejs18.x
	12 - nodejs16.x
	13 - nodejs14.x
	14 - python3.9
	15 - python3.8
	16 - python3.7
	17 - python3.11
	18 - python3.10
	19 - ruby3.2
	20 - ruby2.7
	21 - rust (provided.al2)
Runtime: 19

What package type would you like to use?
	1 - Zip
	2 - Image
Package type: 1

Based on your selections, the only dependency manager available is bundler.
We will proceed copying the template using bundler.

Would you like to enable X-Ray tracing on the function(s) in your application?  [y/N]:

Would you like to enable monitoring using CloudWatch Application Insights?
For more info, please view https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch-application-insights.html [y/N]:

Project name [sam-app]:

    -----------------------
    Generating application:
    -----------------------
    Name: sam-app
    Runtime: ruby3.2
    Architectures: x86_64
    Dependency Manager: bundler
    Application Template: hello-world
    Output Directory: .
    Configuration file: sam-app/samconfig.toml

    Next steps can be found in the README file at sam-app/README.md


Commands you can use next
=========================
[*] Create pipeline: cd sam-app && sam pipeline init --bootstrap
[*] Validate SAM template: cd sam-app && sam validate
[*] Test Function in the Cloud: cd sam-app && sam sync --stack-name {stack-name} --watch
```

作成が完了したら、GitHubにリポジトリを作成して `git push` をしましょう。

```sh
$ git init
$ git remote add origin git@github.com:yuuu/sam-app.git
$ git add .
$ git commit -m 'Initialize'
$ git push origin main
```

これにて準備は完了です。

## Pipelineの構築

以下コマンドを実行することでPipelineを構築します。

:::message
たくさん質問があるので、間違えないように回答するようにしてください。
各回答の意図は適宜コメントで解説します。
:::

### 最初のステージの作成

```sh
$ sam pipeline init --bootstrap

sam pipeline init generates a pipeline configuration file that your CI/CD system
can use to deploy serverless applications using AWS SAM.
We will guide you through the process to bootstrap resources for each stage,
then walk through the details necessary for creating the pipeline config file.

Please ensure you are in the root folder of your SAM application before you begin.

Select a pipeline template to get started:
        1 - AWS Quick Start Pipeline Templates
        2 - Custom Pipeline Template Location
Choice: 1 # AWS Quick Start Pipeline Templatesを利用します
                                                                                                            
Cloning from https://github.com/aws/aws-sam-cli-pipeline-init-templates.git (process may take a moment)     
Select CI/CD system
        1 - Jenkins
        2 - GitLab CI/CD
        3 - GitHub Actions
        4 - Bitbucket Pipelines
        5 - AWS CodePipeline
Choice: 3 # GitHub Actionsを利用します
You are using the 2-stage pipeline template.
 _________    _________ 
|         |  |         |
| Stage 1 |->| Stage 2 |
|_________|  |_________|

Checking for existing stages...

[!] None detected in this account.

Do you want to go through stage setup process now? If you choose no, you can still reference other bootstrapped resources. [Y/n]: # 今の時点でstageは作成しておらず、すぐに作成したいのでそのままEnter

For each stage, we will ask for [1] stage definition, [2] account details, and [3]
reference application build resources in order to bootstrap these pipeline
resources.

We recommend using an individual AWS account profiles for each stage in your
pipeline. You can set these profiles up using aws configure or ~/.aws/credentials. See
[https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-getting-started-set-up-credentials.html].


Stage 1 Setup

[1] Stage definition
Enter a configuration name for this stage. This will be referenced later when you use the sam pipeline init command:
Stage configuration name: dev # devというステージ名にします

[2] Account details
The following AWS credential sources are available to use.
To know more about configuration AWS credentials, visit the link below:
https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html                
        1 - Environment variables (not available)
        2 - profile1 (named profile)
        3 - profile2 (named profile)
        4 - profile3 (named profile)
        q - Quit and configure AWS credentials
Select a credential source to associate with this stage: 1 # ここは使いたい認証方法を選択ください
Associated account xxxxxxxxxxxx with configuration dev.

Enter the region in which you want these resources to be created [ap-northeast-1]: # 東京リージョンを使うのでそのままEnter
Select a user permissions provider:
        1 - IAM (default)
        2 - OpenID Connect (OIDC)
Choice (1, 2): # 特に指定がないのでそのままEnter
Enter the pipeline IAM user ARN if you have previously created one, or we will create one for you []: # 特に指定がないのでそのままEnter

[3] Reference application build resources
Enter the pipeline execution role ARN if you have previously created one, or we will create one for you []: # 特に指定がないのでそのままEnter
Enter the CloudFormation execution role ARN if you have previously created one, or we will create one for you []: # 特に指定がないのでそのままEnter
Please enter the artifact bucket ARN for your Lambda function. If you do not have a bucket, we will create one for you []: # 特に指定がないのでそのままEnter
Does your application contain any IMAGE type Lambda functions? [y/N]: # コンテナイメージのLambda関数は使わないのでそのままEnter

[4] Summary
Below is the summary of the answers:
        1 - Account: xxxxxxxxxxxx 
        2 - Stage configuration name: dev
        3 - Region: ap-northeast-1
        4 - Pipeline user: [to be created]
        5 - Pipeline execution role: [to be created]
        6 - CloudFormation execution role: [to be created]
        7 - Artifacts bucket: [to be created]
        8 - ECR image repository: [skipped]
Press enter to confirm the values above, or select an item to edit the value: # 修正したい項目はないのでそのままEnter

This will create the following required resources for the 'dev' configuration: 
        - Pipeline IAM user
        - Pipeline execution role
        - CloudFormation execution role
        - Artifact bucket
Should we proceed with the creation? [y/N]: y # 今作るのでYesを選択
        Creating the required resources...
        Successfully created!
The following resources were created in your account:
        - Pipeline execution role
        - CloudFormation execution role
        - Artifact bucket
        - Pipeline IAM user
Pipeline IAM user credential: # ここは手元に残しておきましょう
        AWS_ACCESS_KEY_ID: XXXXXXXXXXXXXXXXXXXX
        AWS_SECRET_ACCESS_KEY: XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
View the definition in .aws-sam/pipeline/pipelineconfig.toml,
run sam pipeline bootstrap to generate another set of resources, or proceed to
sam pipeline init to create your pipeline configuration file.

Before running sam pipeline init, we recommend first setting up AWS credentials
in your CI/CD account. Read more about how to do so with your provider in
https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-generating-example-ci-cd-others.html.
```

実際にはまだ質問が続くのですが、一旦ここまでが最初のステージの設定となります。

:::message
終盤に表示された `AWS_ACCESS_KEY_ID` と `AWS_SECRET_ACCESS_KEY` は後ほどGitHub Actionsに設定する必要があるので、手元に残しておくようにしましょう。
:::

### 2つ目のステージの作成

続いて、2つ目のステージのセットアップをします。

```sh
Checking for existing stages...

Only 1 stage(s) were detected, fewer than what the template requires: 2. If these are incorrect, delete .aws-sam/pipeline/pipelineconfig.toml and rerun

Do you want to go through stage setup process now? If you choose no, you can still reference other bootstrapped resources. [Y/n]: # 2つ目のステージのセットアップをするためそのままEnter
For each stage, we will ask for [1] stage definition, [2] account details, and [3]
reference application build resources in order to bootstrap these pipeline
resources.

We recommend using an individual AWS account profiles for each stage in your
pipeline. You can set these profiles up using aws configure or ~/.aws/credentials. See
[https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-getting-started-set-up-credentials.html].


Stage 2 Setup

[1] Stage definition
Enter a configuration name for this stage. This will be referenced later when you use the sam pipeline init command:
Stage configuration name: prod

[2] Account details
The following AWS credential sources are available to use.
To know more about configuration AWS credentials, visit the link below:
https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html                
        1 - Environment variables (not available)
        2 - amplify-personal (named profile)
        3 - default (named profile)
        4 - fusic-sandbox (named profile)
        q - Quit and configure AWS credentials
Select a credential source to associate with this stage: 3
Associated account xxxxxxxxxxxx with configuration prod.

Enter the region in which you want these resources to be created [ap-northeast-1]: # 東京リージョンを使うのでそのままEnter
Pipeline IAM user ARN: arn:aws:iam::xxxxxxxxxxxx:user/aws-sam-cli-managed-dev-pipeline-reso-PipelineUser-XXXXXXXXXXXX

[3] Reference application build resources
Enter the pipeline execution role ARN if you have previously created one, or we will create one for you []: # 特に指定がないのでそのままEnter
Enter the CloudFormation execution role ARN if you have previously created one, or we will create one for you []: # 特に指定がないのでそのままEnter
Please enter the artifact bucket ARN for your Lambda function. If you do not have a bucket, we will create one for you []: # 特に指定がないのでそのままEnter
Does your application contain any IMAGE type Lambda functions? [y/N]: # コンテナイメージのLambda関数は使わないのでそのままEnter

[4] Summary
Below is the summary of the answers:
        1 - Account: xxxxxxxxxxxx 
        2 - Stage configuration name: prod
        3 - Region: ap-northeast-1
        4 - Pipeline user ARN: arn:aws:iam::xxxxxxxxxxxx:user/aws-sam-cli-managed-dev-pipeline-reso-PipelineUser-XXXXXXXXXXXX
        5 - Pipeline execution role: [to be created]
        6 - CloudFormation execution role: [to be created]
        7 - Artifacts bucket: [to be created]
        8 - ECR image repository: [skipped]
Press enter to confirm the values above, or select an item to edit the value: # 修正したい項目はないのでそのままEnter

This will create the following required resources for the 'prod' configuration: 
        - Pipeline execution role
        - CloudFormation execution role
        - Artifact bucket
Should we proceed with the creation? [y/N]: y # 今作るのでYesを選択
        Creating the required resources...
        Successfully created!
The following resources were created in your account:
        - Pipeline execution role
        - CloudFormation execution role
        - Artifact bucket
View the definition in .aws-sam/pipeline/pipelineconfig.toml,
run sam pipeline bootstrap to generate another set of resources, or proceed to
sam pipeline init to create your pipeline configuration file.
```

ここまでで無事2つのステージの作成が完了しました。
質問はまだ続くので、ここで終わらないように注意です。

### GitHub Actionsの設定

最後にGitHub ActionsとPipelineの構成に関する質問があります。

```sh
Checking for existing stages...

2 stage(s) were detected, matching the template requirements. If these are incorrect, delete .aws-sam/pipeline/pipelineconfig.toml and rerun

This template configures a pipeline that deploys a serverless application to a testing and a production stage.

What is the GitHub secret name for pipeline user account access key ID? [AWS_ACCESS_KEY_ID]: # この名前でGitHub secretを指定する予定なのでそのままEnter
What is the GitHub Secret name for pipeline user account access key secret? [AWS_SECRET_ACCESS_KEY]: # この名前でGitHub secretを指定する予定なのでそのままEnter
What is the git branch used for production deployments? [main]: # mainブランチをproductionデプロイするのでそのままEnter
What is the template file path? [template.yaml]: # SAMテンプレートファイルのPathを指定する。今回はデフォルトのままなのでそのままEnter
We use the stage configuration name to automatically retrieve the bootstrapped resources created when you ran `sam pipeline bootstrap`.

Here are the stage configuration names detected in .aws-sam/pipeline/pipelineconfig.toml:
        1 - dev
        2 - prod
Select an index or enter the stage 1's configuration name (as provided during the bootstrapping): dev # 最初のステージを選択するように言われているので 1(dev) を選択
What is the sam application stack name for stage 1? [sam-app]: sam-app-dev # 最初のステージのCloudFormationのスタック名を指定する。sam-app-dev としました
Stage 1 configured successfully, configuring stage 2.

Here are the stage configuration names detected in .aws-sam/pipeline/pipelineconfig.toml:
        1 - dev
        2 - prod
Select an index or enter the stage 2's configuration name (as provided during the bootstrapping): prod # 2つ目のステージを選択するように言われているので 2(prod) を選択
What is the sam application stack name for stage 2? [sam-app]: sam-app-prod # 2つ目のステージのCloudFormationのスタック名を指定する。sam-app-prod としまし
Stage 2 configured successfully.

SUMMARY
We will generate a pipeline config file based on the following information:
        Select a user permissions provider.: AWS IAM
        What is the GitHub secret name for pipeline user account access key ID?: AWS_ACCESS_KEY_ID
        What is the GitHub Secret name for pipeline user account access key secret?: AWS_SECRET_ACCESS_KEY
        What is the git branch used for production deployments?: main
        What is the template file path?: template.yaml
        Select an index or enter the stage 1's configuration name (as provided during the bootstrapping): dev
        What is the sam application stack name for stage 1?: sam-app-dev
        What is the pipeline execution role ARN for stage 1?: arn:aws:iam::xxxxxxxxxxxx:role/aws-sam-cli-managed-dev-pipe-PipelineExecutionRole-XXXXXXXXXXXXX
        What is the CloudFormation execution role ARN for stage 1?: arn:aws:iam::xxxxxxxxxxxx:role/aws-sam-cli-managed-dev-p-CloudFormationExecutionR-XXXXXXXXXXXX
        What is the S3 bucket name for artifacts for stage 1?: aws-sam-cli-managed-dev-pipeline-artifactsbucket-xxxxxxxxxxxxx
        What is the ECR repository URI for stage 1?: 
        What is the AWS region for stage 1?: ap-northeast-1
        Select an index or enter the stage 2's configuration name (as provided during the bootstrapping): prod
        What is the sam application stack name for stage 2?: sam-app-prod
        What is the pipeline execution role ARN for stage 2?: arn:aws:iam::xxxxxxxxxxxx:role/aws-sam-cli-managed-prod-pip-PipelineExecutionRole-XXXXXXXXXXXXX
        What is the CloudFormation execution role ARN for stage 2?: arn:aws:iam::xxxxxxxxxxxx:role/aws-sam-cli-managed-prod-CloudFormationExecutionR-XXXXXXXXXXXX
        What is the S3 bucket name for artifacts for stage 2?: aws-sam-cli-managed-prod-pipeline-artifactsbucket-xxxxxxxxxxxxx
        What is the ECR repository URI for stage 2?: 
        What is the AWS region for stage 2?: ap-northeast-1
Successfully created the pipeline configuration file(s):
        - .github/workflows/pipeline.yaml
```

`.github/workflows/pipeline.yaml` が生成され、このYAMLファイルの中にGitHub Actionsで実行するCI/CDの内容が記述されています。

### GitHubリポジトリにシークレットを作成

GitHub Actionsの中で使用する環境変数をシークレットとして作成します。シークレットの作成手順は以下ドキュメントを参照ください。

https://docs.github.com/ja/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-a-repository

[最初のステージの作成](#最初のステージの作成) でメモした `AWS_ACCESS_KEY_ID` と `AWS_SECRET_ACCESS_KEY` をそのまま登録すればOKです。

![](https://storage.googleapis.com/zenn-user-upload/25b6da86ac49-20230926.png)

以上で構築作業は完了です。

## 動作確認

### ファイル一式をgit push

作成したファイルをGitHubにpushすることで、GitHub Actionsが実行されデプロイされます。

```sh
$ git add .
$ git commit -m 'Add pipeline.yaml for GitHub Actions.'
$ git push origin main
```

リポジトリの `Actions` にアクセスすると、実行状況を確認することができます。
無事にCI/CDが動作すると、以下のように全てがGreen(成功)となります。

![](https://storage.googleapis.com/zenn-user-upload/93a39afcaf0e-20230926.png)

### エラーが出た場合の対処法

ここで `Error: Cannot use both --resolve-s3 and --s3-bucket parameters. Please use only one.` というエラーが出ることがあります。

![](https://storage.googleapis.com/zenn-user-upload/580d3f1fda2a-20230926.png)

これは `samconfig.toml` をpushしている場合に、そのファイルで指定している設定内容とGitHub Actionsで実行している処理内容が競合することが原因です。

以下のいずれかの方法で対処してください。

#### 対処法1. samconfig.tomlをリポジトリに含めない

こちらは、簡単な対処方法です。ビルドやデプロイの設定を共有する必要がないのであれば、リポジトリにこのファイルを含める必要はありません。

次のコマンドで `samconfig.toml` をリポジトリから除外することができます。

```sh
$ echo 'samconfig.toml' >> .gitignore
$ git rm --cache samconfig.toml
$ git add .
$ git commit -m 'Remove samconfig.toml
$ git push origin main
```

#### 対処法2. samconfig.tomlの内容をGitHub Actionsとバッティングしないよう修正する

このプロジェクトをプライベートリポジトリで運用しているケース等で、開発者間で `samconfig.toml` を共有したいシチュエーションがでは、対処法1が採りづらいです。
そういった場合は、 `samconfig.toml` の内容を以下の通り修正することで、GitHub Actionsとのバッティングを回避できます。

- `confirm_changeset` を `false` にする
- `resolve_s3` を全て `false` にする

ただし、この方法だと今度は手元のCLIで `sam deploy` するときにエラーが発生してしまう懸念があります。その場合は以下記事を参考に `sanconfig.toml` の内容を環境ごとに分け、GitHub Actionsでは `default` を、手元の環境では別の環境名を使うようにしましょう。

https://tech.fusic.co.jp/posts/2021-12-09-2021-12-09-aws-sam-samconfig/

## 考察

### ステージを2つ準備したくない場合

`AWS SAM Pipeline` で構築されるCI/CDは2つのステージがある前提となっていますが、実際には「テストはローカル環境やコンテナ上で実行するからステージは1つで良い」というシチュエーションがもあるかもしれません。

残念ながら `AWS SAM Pipeline` で最初から1ステージ構成でパイプラインを構築することはできないので、出来上がった `.github/workflows/pipeline.yaml` を修正することで1ステージ構成にすると良さそうです。

## まとめ

サーバーレスなシステムは、AWS上に作られるリソースが様々なサービスに分散するので、CI/CDの仕組みがおざなりになりがちです。開発の早い段階でCI/CDを構築しておくことで、本番環境を常に最新の状態に保つことができます。

AWS SAMを使う際はぜひお試しください。

## 参考

https://aws.amazon.com/jp/blogs/compute/introducing-aws-sam-pipelines-automatically-generate-deployment-pipelines-for-serverless-applications/
