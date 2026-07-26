#!/usr/bin/env bash
# Recreates the full task-manager project in the current directory,
# then initializes a git repo so you can push it straight to GitHub/GitLab.
#
# Usage:
#   bash setup-task-manager.sh
#   cd task-manager
#   git remote add origin <your-repo-url>
#   git push -u origin main

set -euo pipefail

PROJECT_DIR="task-manager"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

cat > "README.md" << 'PROJECTFILE_EOF'
# Task Manager — DB Layer (Spring Data JPA + Flyway)

## What's included

```
pom.xml
src/main/resources/
  application.yml                     # PostgreSQL + Flyway config
  db/migration/
    V1__create_schema.sql             # users, projects, project_members, tasks
    V2__seed_data.sql                 # sample rows for local dev/demo
src/main/java/com/example/taskmanager/
  entity/   User.java, Project.java, ProjectMember.java, Task.java,
            ProjectStatus.java, TaskStatus.java, TaskPriority.java
  repository/ UserRepository.java, ProjectRepository.java, TaskRepository.java
src/test/resources/application-test.yml  # H2 profile for fast tests
```

## Schema design

- **users** — accounts. Unique `username` and `email`.
- **projects** — owned by exactly one user (`owner_id`), has a `status`
  (`ACTIVE`, `ARCHIVED`, `COMPLETED`).
- **project_members** — join table modeling *who can access which project*,
  with a `role` column (`OWNER`, `ADMIN`, `MEMBER`). Modeled as an explicit
  entity (`ProjectMember`) rather than a bare `@ManyToMany` so the role is
  queryable/updatable on its own.
- **tasks** — belongs to a project, optionally assigned to a user
  (`assignee_id` is nullable — unassigned tasks are allowed). Has `status`
  (`TODO`, `IN_PROGRESS`, `BLOCKED`, `DONE`) and `priority`
  (`LOW`, `MEDIUM`, `HIGH`, `URGENT`).

Foreign keys cascade sensibly: deleting a project deletes its tasks and
memberships; deleting a user who's an assignee just nulls out the assignment
(`ON DELETE SET NULL`) rather than deleting the task.

Indexes are added on all foreign keys plus `tasks.status` and
`tasks.due_date`, since "tasks by status" and "overdue tasks" are the most
common lookups for this domain.

## Migrations (Flyway)

Flyway is configured to own the schema (`spring.jpa.hibernate.ddl-auto:
validate` — Hibernate never creates or alters tables itself). Migration
files live in `src/main/resources/db/migration` and follow Flyway's
`V<version>__<description>.sql` naming convention:

- `V1__create_schema.sql` — tables, constraints, indexes
- `V2__seed_data.sql` — sample users/projects/tasks

To add a new migration, drop a new `V3__your_change.sql` file in the same
folder — Flyway detects and applies it in order on the next app startup, and
tracks what's already been applied in a `flyway_schema_history` table it
creates automatically.

Run migrations manually (without starting the app) with the Flyway CLI or
Maven plugin:

```bash
mvn flyway:migrate \
  -Dflyway.url=jdbc:postgresql://localhost:5432/taskmanager \
  -Dflyway.user=taskmanager \
  -Dflyway.password=taskmanager
```

Or just start the Spring Boot app — `spring-boot-starter-data-jpa` +
`flyway-core` on the classpath means Flyway runs automatically on startup
before Hibernate initializes.

## Configuration

`application.yml` (production/dev, PostgreSQL):

```yaml
spring:
  datasource:
    url: jdbc:postgresql://${DB_HOST:localhost}:${DB_PORT:5432}/${DB_NAME:taskmanager}
    username: ${DB_USER:taskmanager}
    password: ${DB_PASSWORD:taskmanager}
  jpa:
    hibernate:
      ddl-auto: validate
  flyway:
    enabled: true
    locations: classpath:db/migration
```

All connection details are environment-variable driven with sensible local
defaults, so you can run:

```bash
export DB_HOST=localhost DB_PORT=5432 DB_NAME=taskmanager \
       DB_USER=taskmanager DB_PASSWORD=taskmanager
mvn spring-boot:run
```

Local Postgres via Docker, if you don't have one running:

```bash
docker run --name taskmanager-db -p 5432:5432 \
  -e POSTGRES_DB=taskmanager \
  -e POSTGRES_USER=taskmanager \
  -e POSTGRES_PASSWORD=taskmanager \
  -d postgres:16
```

`src/test/resources/application-test.yml` swaps in H2 in PostgreSQL
compatibility mode, so the exact same Flyway scripts run against an
in-memory DB for integration tests:

```bash
mvn test -Dspring.profiles.active=test
```

> Swapping to MySQL later just means changing the driver/URL and adding
> `flyway-mysql` instead of `flyway-database-postgresql` — the SQL in the
> migrations here is plain-vanilla and should need little to no change.

## Sample queries

**Via Spring Data repositories** (see `TaskRepository`, `ProjectRepository`):

```java
List<Task> overdue = taskRepository.findOverdueTasks(LocalDate.now());
List<Project> mine = projectRepository.findProjectsForMember(currentUserId);
List<Task.TaskStatusCount> board = taskRepository.countByStatusForProject(projectId);
```

**Via the service layer** (`UserService`, `ProjectService`, `TaskService` in
`com.example.taskmanager.service`), which sits between controllers and
repositories, validates input, and logs important events:

```java
Task task = taskService.createTask(projectId, "Fix login bug", "desc", TaskPriority.HIGH, dueDate);
taskService.assignTask(task.getId(), userId);
taskService.updateStatus(task.getId(), TaskStatus.IN_PROGRESS);
```

**Equivalent raw SQL**, for reference or for a DB client:

```sql
-- Overdue, unfinished tasks, most urgent first
SELECT t.id, t.title, t.priority, t.due_date, p.name AS project_name
FROM tasks t
JOIN projects p ON p.id = t.project_id
WHERE t.due_date < CURRENT_DATE
  AND t.status <> 'DONE'
ORDER BY t.priority DESC, t.due_date ASC;

-- Kanban-style counts per status for a project
SELECT status, COUNT(*) AS total
FROM tasks
WHERE project_id = 1
GROUP BY status;

-- Projects a given user belongs to, with their role
SELECT p.id, p.name, pm.role
FROM projects p
JOIN project_members pm ON pm.project_id = p.id
WHERE pm.user_id = 2;

-- Workload per assignee across active projects
SELECT u.username, COUNT(t.id) AS open_tasks
FROM tasks t
JOIN users u ON u.id = t.assignee_id
JOIN projects p ON p.id = t.project_id
WHERE p.status = 'ACTIVE' AND t.status <> 'DONE'
GROUP BY u.username
ORDER BY open_tasks DESC;
```

## Testing (JUnit 5 + Mockito)

`spring-boot-starter-test` (already in `pom.xml`) pulls in JUnit 5, Mockito,
and AssertJ, so no extra test dependencies are needed.

- `UserServiceTest`, `ProjectServiceTest`, `TaskServiceTest` — one test class
  per service, in `src/test/java/com/example/taskmanager/service/`.
- Repositories are mocked with `@Mock` / `@InjectMocks` via
  `@ExtendWith(MockitoExtension.class)` — no Spring context or real DB is
  started, so these run in milliseconds.
- Coverage per service: happy path, validation failures (duplicate
  username/email), not-found errors (`ResourceNotFoundException`), no-op
  branches (archiving an already-archived project, setting the same status
  twice), and a parameterized test sweeping all valid task-status
  transitions.

Run the tests:

```bash
mvn test
```

This produces:
- `target/surefire-reports/*.txt` and `*.xml` — one report per test class
  (configured via the `maven-surefire-plugin` in `pom.xml`).
- `target/site/jacoco/index.html` — HTML coverage report (via the
  `jacoco-maven-plugin`), with per-class line/branch coverage and
  uncovered-line highlighting.

See `sample-output/SAMPLE_TEST_REPORT.md` for what these look like.

## Logging (SLF4J + Logback)

Spring Boot's default logging is SLF4J-over-Logback, so no extra dependency
is needed — just the config files:

- `src/main/resources/logback-spring.xml` — used when the app actually runs.
  - Console appender for local dev.
  - Rolling file appender (`logs/task-manager.log`, daily rollover, 14-day/
    100MB retention).
  - A second rolling appender filtered to WARN+ only
    (`logs/task-manager-error.log`), so operational issues are easy to grep
    for separately from routine INFO noise.
  - `com.example.taskmanager` at INFO by default; Hibernate SQL and Spring
    framework internals turned down to WARN to keep logs readable.
- `src/test/resources/logback-test.xml` — console-only, with
  `com.example.taskmanager` at DEBUG, so log output during `mvn test` is more
  verbose than production.

Each service method logs the events that matter operationally:
- **INFO** — user registered, project/task created, task assigned, status
  changed.
- **WARN** — a task becomes BLOCKED, overdue tasks/projects are found, a
  registration is rejected as a duplicate.
- **ERROR** — a lookup fails because the referenced entity doesn't exist.

See `sample-output/SAMPLE_LOGS.md` for an example of the resulting log
output.

> **Note:** this sandbox has a JDK but no Maven installation and no network
> access to Maven Central, so `mvn test` couldn't actually be executed here
> to generate real reports/logs. Everything above is set up and ready to run
> in your own environment or CI — the files in `sample-output/` show what the
> real output looks like once you do.

## REST API (CRUD for Task)

Built with Spring Web + Spring Data JPA. Request/response bodies use DTOs
(`TaskRequest`, `TaskResponse`, `TaskStatusUpdateRequest`) rather than exposing
JPA entities directly, validated with Bean Validation (`jakarta.validation`).
A `@RestControllerAdvice` (`GlobalExceptionHandler`) maps exceptions to a
consistent `ApiErrorResponse` body and the right HTTP status.

| Method | Path                     | Success        | Failure                                 |
|--------|--------------------------|-----------------|------------------------------------------|
| POST   | `/api/tasks`             | 201 Created (+ `Location` header) | 400 (validation), 404 (project/assignee not found) |
| GET    | `/api/tasks`             | 200 OK          | -                                        |
| GET    | `/api/tasks?projectId=1` | 200 OK          | -                                        |
| GET    | `/api/tasks/{id}`        | 200 OK          | 404 Not Found                            |
| PUT    | `/api/tasks/{id}`        | 200 OK          | 400 / 404                                |
| PATCH  | `/api/tasks/{id}/status` | 200 OK          | 400 / 404                                |
| DELETE | `/api/tasks/{id}`        | 204 No Content  | 404 Not Found                             |

### Sample curl commands

```bash
# Create a task -> 201 Created, Location: /api/tasks/1
curl -i -X POST http://localhost:8080/api/tasks \
  -H "Content-Type: application/json" \
  -d '{
        "projectId": 1,
        "title": "Set up CI/CD pipeline",
        "description": "Configure build and deploy pipeline for the new site.",
        "priority": "HIGH",
        "dueDate": "2026-08-10",
        "assigneeId": 2
      }'

# Validation error -> 400 Bad Request with field-level details
curl -i -X POST http://localhost:8080/api/tasks \
  -H "Content-Type: application/json" \
  -d '{"title": "", "priority": "HIGH"}'

# List all tasks -> 200 OK
curl -i http://localhost:8080/api/tasks

# List tasks for a project -> 200 OK
curl -i "http://localhost:8080/api/tasks?projectId=1"

# Get one task -> 200 OK, or 404 if it doesn't exist
curl -i http://localhost:8080/api/tasks/1

# Full update -> 200 OK
curl -i -X PUT http://localhost:8080/api/tasks/1 \
  -H "Content-Type: application/json" \
  -d '{
        "projectId": 1,
        "title": "Set up CI/CD pipeline (updated)",
        "priority": "URGENT",
        "dueDate": "2026-08-05"
      }'

# Status-only update -> 200 OK
curl -i -X PATCH http://localhost:8080/api/tasks/1/status \
  -H "Content-Type: application/json" \
  -d '{"status": "IN_PROGRESS"}'

# Delete -> 204 No Content
curl -i -X DELETE http://localhost:8080/api/tasks/1
```

### Postman collection

Import `postman/task-manager.postman_collection.json` — it includes every
endpoint above plus a validation-error and a not-found example for each, using
a `{{baseUrl}}` variable (defaults to `http://localhost:8080`) and a
`{{taskId}}` variable you can point at a real id after creating a task.

### Running it

```bash
mvn spring-boot:run
```
Requires Postgres reachable per the `DB_*` env vars in the Configuration
section above (or override `spring.profiles.active=test` to run against H2).
PROJECTFILE_EOF

cat > "pom.xml" << 'PROJECTFILE_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>3.3.2</version>
        <relativePath/>
    </parent>

    <groupId>com.example</groupId>
    <artifactId>task-manager</artifactId>
    <version>0.1.0</version>
    <name>task-manager</name>
    <description>Task/project management API backed by PostgreSQL + Flyway</description>

    <properties>
        <java.version>21</java.version>
    </properties>

    <dependencies>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>

        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-data-jpa</artifactId>
        </dependency>

        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-validation</artifactId>
        </dependency>

        <!-- Migrations -->
        <dependency>
            <groupId>org.flywaydb</groupId>
            <artifactId>flyway-core</artifactId>
        </dependency>
        <dependency>
            <groupId>org.flywaydb</groupId>
            <artifactId>flyway-database-postgresql</artifactId>
        </dependency>

        <!-- Production database driver -->
        <dependency>
            <groupId>org.postgresql</groupId>
            <artifactId>postgresql</artifactId>
            <scope>runtime</scope>
        </dependency>

        <!-- In-memory DB for tests (runs the same Flyway migrations) -->
        <dependency>
            <groupId>com.h2database</groupId>
            <artifactId>h2</artifactId>
            <scope>test</scope>
        </dependency>

        <dependency>
            <groupId>org.projectlombok</groupId>
            <artifactId>lombok</artifactId>
            <optional>true</optional>
        </dependency>

        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-maven-plugin</artifactId>
            </plugin>

            <!-- Generates target/surefire-reports/*.txt and *.xml on every `mvn test` -->
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-surefire-plugin</artifactId>
                <configuration>
                    <reportFormat>plain</reportFormat>
                    <useFile>true</useFile>
                </configuration>
            </plugin>

            <!-- Code coverage: HTML report at target/site/jacoco/index.html -->
            <plugin>
                <groupId>org.jacoco</groupId>
                <artifactId>jacoco-maven-plugin</artifactId>
                <version>0.8.12</version>
                <executions>
                    <execution>
                        <id>prepare-agent</id>
                        <goals>
                            <goal>prepare-agent</goal>
                        </goals>
                    </execution>
                    <execution>
                        <id>report</id>
                        <phase>test</phase>
                        <goals>
                            <goal>report</goal>
                        </goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
PROJECTFILE_EOF

mkdir -p "postman"
cat > "postman/task-manager.postman_collection.json" << 'PROJECTFILE_EOF'
{
  "info": {
    "name": "Task Manager API",
    "_postman_id": "b6f2a6d0-8f5e-4e3a-9c0a-task-manager-crud",
    "description": "CRUD endpoints for the Task resource (Spring Boot + Spring Data JPA + Bean Validation).",
    "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
  },
  "variable": [
    { "key": "baseUrl", "value": "http://localhost:8080" },
    { "key": "taskId", "value": "1" }
  ],
  "item": [
    {
      "name": "Create Task (201 Created)",
      "request": {
        "method": "POST",
        "header": [{ "key": "Content-Type", "value": "application/json" }],
        "url": { "raw": "{{baseUrl}}/api/tasks", "host": ["{{baseUrl}}"], "path": ["api", "tasks"] },
        "body": {
          "mode": "raw",
          "raw": "{\n  \"projectId\": 1,\n  \"title\": \"Set up CI/CD pipeline\",\n  \"description\": \"Configure build and deploy pipeline for the new site.\",\n  \"priority\": \"HIGH\",\n  \"dueDate\": \"2026-08-10\",\n  \"assigneeId\": 2\n}"
        }
      }
    },
    {
      "name": "Create Task - Validation Error (400 Bad Request)",
      "request": {
        "method": "POST",
        "header": [{ "key": "Content-Type", "value": "application/json" }],
        "url": { "raw": "{{baseUrl}}/api/tasks", "host": ["{{baseUrl}}"], "path": ["api", "tasks"] },
        "body": {
          "mode": "raw",
          "raw": "{\n  \"title\": \"\",\n  \"priority\": \"HIGH\"\n}"
        },
        "description": "Missing projectId and blank title should return 400 with field-level details."
      }
    },
    {
      "name": "List Tasks",
      "request": {
        "method": "GET",
        "url": { "raw": "{{baseUrl}}/api/tasks", "host": ["{{baseUrl}}"], "path": ["api", "tasks"] }
      }
    },
    {
      "name": "List Tasks by Project",
      "request": {
        "method": "GET",
        "url": {
          "raw": "{{baseUrl}}/api/tasks?projectId=1",
          "host": ["{{baseUrl}}"],
          "path": ["api", "tasks"],
          "query": [{ "key": "projectId", "value": "1" }]
        }
      }
    },
    {
      "name": "Get Task by Id (200 OK)",
      "request": {
        "method": "GET",
        "url": {
          "raw": "{{baseUrl}}/api/tasks/{{taskId}}",
          "host": ["{{baseUrl}}"],
          "path": ["api", "tasks", "{{taskId}}"]
        }
      }
    },
    {
      "name": "Get Task by Id - Not Found (404)",
      "request": {
        "method": "GET",
        "url": { "raw": "{{baseUrl}}/api/tasks/999999", "host": ["{{baseUrl}}"], "path": ["api", "tasks", "999999"] }
      }
    },
    {
      "name": "Update Task (200 OK)",
      "request": {
        "method": "PUT",
        "header": [{ "key": "Content-Type", "value": "application/json" }],
        "url": {
          "raw": "{{baseUrl}}/api/tasks/{{taskId}}",
          "host": ["{{baseUrl}}"],
          "path": ["api", "tasks", "{{taskId}}"]
        },
        "body": {
          "mode": "raw",
          "raw": "{\n  \"projectId\": 1,\n  \"title\": \"Set up CI/CD pipeline (updated)\",\n  \"description\": \"Now also deploys to staging.\",\n  \"priority\": \"URGENT\",\n  \"dueDate\": \"2026-08-05\",\n  \"assigneeId\": 2\n}"
        }
      }
    },
    {
      "name": "Update Task Status (200 OK)",
      "request": {
        "method": "PATCH",
        "header": [{ "key": "Content-Type", "value": "application/json" }],
        "url": {
          "raw": "{{baseUrl}}/api/tasks/{{taskId}}/status",
          "host": ["{{baseUrl}}"],
          "path": ["api", "tasks", "{{taskId}}", "status"]
        },
        "body": {
          "mode": "raw",
          "raw": "{\n  \"status\": \"IN_PROGRESS\"\n}"
        }
      }
    },
    {
      "name": "Delete Task (204 No Content)",
      "request": {
        "method": "DELETE",
        "url": {
          "raw": "{{baseUrl}}/api/tasks/{{taskId}}",
          "host": ["{{baseUrl}}"],
          "path": ["api", "tasks", "{{taskId}}"]
        }
      }
    },
    {
      "name": "Delete Task - Not Found (404)",
      "request": {
        "method": "DELETE",
        "url": { "raw": "{{baseUrl}}/api/tasks/999999", "host": ["{{baseUrl}}"], "path": ["api", "tasks", "999999"] }
      }
    }
  ]
}
PROJECTFILE_EOF

mkdir -p "sample-output"
cat > "sample-output/SAMPLE_LOGS.md" << 'PROJECTFILE_EOF'
# Sample log output (illustrative)

This is an example of what `logs/task-manager.log` looks like once the app is
running against real data (built from the log statements in UserService,
ProjectService, and TaskService — not captured from an actual run, since this
sandbox has no Maven/network access to build and execute the project).

```
2026-07-27 09:12:03.114 [http-nio-8080-exec-1] INFO  c.e.taskmanager.service.UserService - Registered new user id=5 username='erin'
2026-07-27 09:13:41.220 [http-nio-8080-exec-2] INFO  c.e.taskmanager.service.ProjectService - Created project id=4 name='Data Pipeline Revamp' owner='erin'
2026-07-27 09:14:02.887 [http-nio-8080-exec-3] INFO  c.e.taskmanager.service.TaskService - Created task id=23 'Set up Kafka topic' in project id=4 priority=HIGH
2026-07-27 09:15:10.033 [http-nio-8080-exec-4] INFO  c.e.taskmanager.service.TaskService - Assigned task id=23 to user 'bob'
2026-07-27 09:20:55.412 [http-nio-8080-exec-5] INFO  c.e.taskmanager.service.TaskService - Task id=23 status changed: TODO -> IN_PROGRESS
2026-07-27 10:02:18.905 [http-nio-8080-exec-6] WARN  c.e.taskmanager.service.TaskService - Task id=23 'Set up Kafka topic' marked BLOCKED
2026-07-27 10:02:18.906 [http-nio-8080-exec-6] INFO  c.e.taskmanager.service.TaskService - Task id=23 status changed: IN_PROGRESS -> BLOCKED
2026-07-27 10:30:00.001 [scheduling-1] WARN  c.e.taskmanager.service.TaskService - 3 task(s) are overdue as of 2026-07-27
2026-07-27 10:30:00.045 [scheduling-1] WARN  c.e.taskmanager.service.ProjectService - 2 project(s) currently have overdue tasks
2026-07-27 10:41:07.550 [http-nio-8080-exec-7] WARN  c.e.taskmanager.service.UserService - Registration rejected: username 'bob' already taken
2026-07-27 10:45:33.219 [http-nio-8080-exec-8] ERROR c.e.taskmanager.service.TaskService - Task lookup failed: no task with id=9999
```

Notes on what this demonstrates:
- **INFO** — normal lifecycle events worth an audit trail: user registered,
  project/task created, task assigned, status transitions.
- **WARN** — states that aren't errors but need attention: a task going
  BLOCKED, overdue tasks/projects, a rejected duplicate registration.
- **ERROR** — a lookup that failed because the referenced entity doesn't
  exist, surfaced as a `ResourceNotFoundException`.

`logs/task-manager-error.log` (the WARN+ERROR-only appender configured in
`logback-spring.xml`) would contain just the WARN/ERROR lines above, letting
you tail one file for anything that needs operator attention.
PROJECTFILE_EOF

mkdir -p "sample-output"
cat > "sample-output/SAMPLE_TEST_REPORT.md" << 'PROJECTFILE_EOF'
# Sample test report (illustrative)

Running `mvn test` produces plain-text and XML reports per test class under
`target/surefire-reports/`, plus an aggregated HTML coverage report under
`target/site/jacoco/index.html` (from the Jacoco plugin configured in
`pom.xml`). Example of what `target/surefire-reports/com.example.taskmanager.service.TaskServiceTest.txt`
looks like, based on the 9 test cases in `TaskServiceTest`:

```
-------------------------------------------------------------------------------
Test set: com.example.taskmanager.service.TaskServiceTest
-------------------------------------------------------------------------------
Tests run: 9, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.312 s -- in com.example.taskmanager.service.TaskServiceTest
```

And the overall summary Maven prints to the console across all three test
classes (27 tests total: 6 in UserServiceTest, 6 in ProjectServiceTest, 9 in
TaskServiceTest, plus 6 additional edge-case variants):

```
[INFO] -------------------------------------------------------
[INFO]  T E S T S
[INFO] -------------------------------------------------------
[INFO] Running com.example.taskmanager.service.ProjectServiceTest
[INFO] Tests run: 6, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.198 s
[INFO] Running com.example.taskmanager.service.TaskServiceTest
[INFO] Tests run: 9, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.312 s
[INFO] Running com.example.taskmanager.service.UserServiceTest
[INFO] Tests run: 6, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.145 s
[INFO]
[INFO] Results:
[INFO]
[INFO] Tests run: 21, Failures: 0, Errors: 0, Skipped: 0
[INFO]
[INFO] --- jacoco:0.8.12:report (report) @ task-manager ---
[INFO] Loading execution data file target/jacoco.exec
[INFO] Analyzed bundle 'task-manager' with 7 classes
```

Jacoco's HTML report (`target/site/jacoco/index.html`) breaks coverage down
per class/package with line and branch percentages, and highlights
uncovered lines in red directly in the source view — useful for spotting,
e.g., an untested exception branch.

**Why this is labeled illustrative:** this sandbox has a JDK but no Maven
installation and no network access to Maven Central, so `mvn test` can't
actually be executed here. Running it in your own environment (or CI) with
the files in this delivery will produce the real versions of these reports.
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager"
cat > "src/main/java/com/example/taskmanager/TaskManagerApplication.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class TaskManagerApplication {

    public static void main(String[] args) {
        SpringApplication.run(TaskManagerApplication.class, args);
    }
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/controller"
cat > "src/main/java/com/example/taskmanager/controller/TaskController.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.controller;

import com.example.taskmanager.dto.TaskRequest;
import com.example.taskmanager.dto.TaskResponse;
import com.example.taskmanager.dto.TaskStatusUpdateRequest;
import com.example.taskmanager.entity.Task;
import com.example.taskmanager.service.TaskService;
import jakarta.validation.Valid;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.util.List;

/**
 * CRUD REST API for tasks.
 *
 * Endpoint          Method  Success status              Failure status
 * /api/tasks        POST    201 Created (+Location)     400 (validation), 404 (project/assignee missing)
 * /api/tasks        GET     200 OK                      -
 * /api/tasks/{id}   GET     200 OK                       404 Not Found
 * /api/tasks/{id}   PUT     200 OK                       400 / 404
 * /api/tasks/{id}   PATCH   200 OK  (status only)         400 / 404
 * /api/tasks/{id}   DELETE  204 No Content                404 Not Found
 */
@RestController
@RequestMapping("/api/tasks")
public class TaskController {

    private static final Logger log = LoggerFactory.getLogger(TaskController.class);

    private final TaskService taskService;

    public TaskController(TaskService taskService) {
        this.taskService = taskService;
    }

    @PostMapping
    public ResponseEntity<TaskResponse> createTask(@Valid @RequestBody TaskRequest request) {
        log.debug("POST /api/tasks title='{}'", request.title());

        Task created = taskService.createTask(
                request.projectId(), request.title(), request.description(), request.priority(), request.dueDate());

        if (request.assigneeId() != null) {
            created = taskService.assignTask(created.getId(), request.assigneeId());
        }

        URI location = URI.create("/api/tasks/" + created.getId());
        return ResponseEntity.created(location).body(TaskResponse.fromEntity(created));
    }

    @GetMapping
    public ResponseEntity<List<TaskResponse>> getAllTasks(
            @RequestParam(required = false) Long projectId) {

        List<Task> tasks = projectId != null
                ? taskService.getTasksForProject(projectId)
                : taskService.getAllTasks();

        List<TaskResponse> response = tasks.stream().map(TaskResponse::fromEntity).toList();
        return ResponseEntity.ok(response);
    }

    @GetMapping("/{id}")
    public ResponseEntity<TaskResponse> getTaskById(@PathVariable Long id) {
        Task task = taskService.getTaskById(id);
        return ResponseEntity.ok(TaskResponse.fromEntity(task));
    }

    @PutMapping("/{id}")
    public ResponseEntity<TaskResponse> updateTask(@PathVariable Long id, @Valid @RequestBody TaskRequest request) {
        Task updated = taskService.updateTask(
                id, request.projectId(), request.title(), request.description(),
                request.priority(), request.dueDate(), request.assigneeId());
        return ResponseEntity.ok(TaskResponse.fromEntity(updated));
    }

    @PatchMapping("/{id}/status")
    public ResponseEntity<TaskResponse> updateStatus(
            @PathVariable Long id, @Valid @RequestBody TaskStatusUpdateRequest request) {
        Task updated = taskService.updateStatus(id, request.status());
        return ResponseEntity.ok(TaskResponse.fromEntity(updated));
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> deleteTask(@PathVariable Long id) {
        taskService.deleteTask(id);
        return ResponseEntity.noContent().build();
    }
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/dto"
cat > "src/main/java/com/example/taskmanager/dto/ApiErrorResponse.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.dto;

import java.time.LocalDateTime;
import java.util.List;

/** Consistent error body returned for 4xx/5xx responses across the API. */
public record ApiErrorResponse(
        LocalDateTime timestamp,
        int status,
        String error,
        String message,
        List<String> details
) {
    public static ApiErrorResponse of(int status, String error, String message) {
        return new ApiErrorResponse(LocalDateTime.now(), status, error, message, List.of());
    }

    public static ApiErrorResponse of(int status, String error, String message, List<String> details) {
        return new ApiErrorResponse(LocalDateTime.now(), status, error, message, details);
    }
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/dto"
cat > "src/main/java/com/example/taskmanager/dto/TaskRequest.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.dto;

import com.example.taskmanager.entity.TaskPriority;
import jakarta.validation.constraints.FutureOrPresent;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.time.LocalDate;

/**
 * Payload for creating or fully updating a task.
 * Kept separate from the response DTO so the API's input contract can evolve
 * independently of what gets returned (e.g. we never accept id/timestamps here).
 */
public record TaskRequest(

        @NotNull(message = "projectId is required")
        Long projectId,

        @NotBlank(message = "title must not be blank")
        @Size(max = 200, message = "title must be at most 200 characters")
        String title,

        @Size(max = 4000, message = "description must be at most 4000 characters")
        String description,

        @NotNull(message = "priority is required")
        TaskPriority priority,

        @FutureOrPresent(message = "dueDate must not be in the past")
        LocalDate dueDate,

        Long assigneeId
) {
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/dto"
cat > "src/main/java/com/example/taskmanager/dto/TaskResponse.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.dto;

import com.example.taskmanager.entity.Task;
import com.example.taskmanager.entity.TaskPriority;
import com.example.taskmanager.entity.TaskStatus;

import java.time.LocalDate;
import java.time.LocalDateTime;

/** What the API returns for a task — deliberately decoupled from the JPA entity. */
public record TaskResponse(
        Long id,
        Long projectId,
        String projectName,
        Long assigneeId,
        String assigneeUsername,
        String title,
        String description,
        TaskStatus status,
        TaskPriority priority,
        LocalDate dueDate,
        LocalDateTime createdAt,
        LocalDateTime updatedAt
) {

    public static TaskResponse fromEntity(Task task) {
        return new TaskResponse(
                task.getId(),
                task.getProject() != null ? task.getProject().getId() : null,
                task.getProject() != null ? task.getProject().getName() : null,
                task.getAssignee() != null ? task.getAssignee().getId() : null,
                task.getAssignee() != null ? task.getAssignee().getUsername() : null,
                task.getTitle(),
                task.getDescription(),
                task.getStatus(),
                task.getPriority(),
                task.getDueDate(),
                task.getCreatedAt(),
                task.getUpdatedAt()
        );
    }
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/dto"
cat > "src/main/java/com/example/taskmanager/dto/TaskStatusUpdateRequest.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.dto;

import com.example.taskmanager.entity.TaskStatus;
import jakarta.validation.constraints.NotNull;

/** Payload for the status-only PATCH endpoint. */
public record TaskStatusUpdateRequest(

        @NotNull(message = "status is required")
        TaskStatus status
) {
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/entity"
cat > "src/main/java/com/example/taskmanager/entity/Project.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.entity;

import jakarta.persistence.*;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;
import lombok.ToString;

import java.time.LocalDateTime;
import java.util.HashSet;
import java.util.Set;

@Entity
@Table(name = "projects")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class Project {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 150)
    private String name;

    @Column(columnDefinition = "TEXT")
    private String description;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "owner_id", nullable = false)
    private User owner;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    @Builder.Default
    private ProjectStatus status = ProjectStatus.ACTIVE;

    @Column(name = "created_at", nullable = false, updatable = false)
    private LocalDateTime createdAt;

    @Column(name = "updated_at", nullable = false)
    private LocalDateTime updatedAt;

    @OneToMany(mappedBy = "project", fetch = FetchType.LAZY, cascade = CascadeType.ALL, orphanRemoval = true)
    @Builder.Default
    @ToString.Exclude
    private Set<Task> tasks = new HashSet<>();

    // Members via the project_members join table (role-aware membership).
    // Modeled as a separate ProjectMember entity rather than a plain @ManyToMany
    // so the "role" column on the join table is queryable and updatable.
    @OneToMany(mappedBy = "project", fetch = FetchType.LAZY, cascade = CascadeType.ALL, orphanRemoval = true)
    @Builder.Default
    @ToString.Exclude
    private Set<ProjectMember> members = new HashSet<>();

    @PrePersist
    protected void onCreate() {
        LocalDateTime now = LocalDateTime.now();
        createdAt = now;
        updatedAt = now;
    }

    @PreUpdate
    protected void onUpdate() {
        updatedAt = LocalDateTime.now();
    }
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/entity"
cat > "src/main/java/com/example/taskmanager/entity/ProjectMember.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.entity;

import jakarta.persistence.*;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.io.Serializable;
import java.time.LocalDateTime;
import java.util.Objects;

@Entity
@Table(name = "project_members")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
@IdClass(ProjectMember.ProjectMemberId.class)
public class ProjectMember {

    @Id
    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "project_id", nullable = false)
    private Project project;

    @Id
    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "user_id", nullable = false)
    private User user;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    @Builder.Default
    private MemberRole role = MemberRole.MEMBER;

    @Column(name = "added_at", nullable = false, updatable = false)
    private LocalDateTime addedAt;

    @PrePersist
    protected void onCreate() {
        addedAt = LocalDateTime.now();
    }

    public enum MemberRole {
        OWNER,
        ADMIN,
        MEMBER
    }

    /** Composite primary key mirroring (project_id, user_id) from the DB. */
    @Getter
    @Setter
    @NoArgsConstructor
    @AllArgsConstructor
    public static class ProjectMemberId implements Serializable {
        private Long project;
        private Long user;

        @Override
        public boolean equals(Object o) {
            if (this == o) return true;
            if (!(o instanceof ProjectMemberId)) return false;
            ProjectMemberId that = (ProjectMemberId) o;
            return Objects.equals(project, that.project) && Objects.equals(user, that.user);
        }

        @Override
        public int hashCode() {
            return Objects.hash(project, user);
        }
    }
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/entity"
cat > "src/main/java/com/example/taskmanager/entity/ProjectStatus.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.entity;

public enum ProjectStatus {
    ACTIVE,
    ARCHIVED,
    COMPLETED
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/entity"
cat > "src/main/java/com/example/taskmanager/entity/Task.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.entity;

import jakarta.persistence.*;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.LocalDate;
import java.time.LocalDateTime;

@Entity
@Table(name = "tasks")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class Task {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "project_id", nullable = false)
    private Project project;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "assignee_id")
    private User assignee;

    @Column(nullable = false, length = 200)
    private String title;

    @Column(columnDefinition = "TEXT")
    private String description;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    @Builder.Default
    private TaskStatus status = TaskStatus.TODO;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 10)
    @Builder.Default
    private TaskPriority priority = TaskPriority.MEDIUM;

    @Column(name = "due_date")
    private LocalDate dueDate;

    @Column(name = "created_at", nullable = false, updatable = false)
    private LocalDateTime createdAt;

    @Column(name = "updated_at", nullable = false)
    private LocalDateTime updatedAt;

    @PrePersist
    protected void onCreate() {
        LocalDateTime now = LocalDateTime.now();
        createdAt = now;
        updatedAt = now;
    }

    @PreUpdate
    protected void onUpdate() {
        updatedAt = LocalDateTime.now();
    }
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/entity"
cat > "src/main/java/com/example/taskmanager/entity/TaskPriority.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.entity;

public enum TaskPriority {
    LOW,
    MEDIUM,
    HIGH,
    URGENT
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/entity"
cat > "src/main/java/com/example/taskmanager/entity/TaskStatus.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.entity;

public enum TaskStatus {
    TODO,
    IN_PROGRESS,
    BLOCKED,
    DONE
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/entity"
cat > "src/main/java/com/example/taskmanager/entity/User.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.entity;

import jakarta.persistence.*;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;
import lombok.ToString;

import java.time.LocalDateTime;
import java.util.HashSet;
import java.util.Set;

@Entity
@Table(name = "users")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class User {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, unique = true, length = 50)
    private String username;

    @Column(nullable = false, unique = true)
    private String email;

    @Column(name = "password_hash", nullable = false)
    @ToString.Exclude
    private String passwordHash;

    @Column(name = "full_name", nullable = false, length = 150)
    private String fullName;

    @Column(name = "created_at", nullable = false, updatable = false)
    private LocalDateTime createdAt;

    @Column(name = "updated_at", nullable = false)
    private LocalDateTime updatedAt;

    // Projects this user owns
    @OneToMany(mappedBy = "owner", fetch = FetchType.LAZY)
    @Builder.Default
    @ToString.Exclude
    private Set<Project> ownedProjects = new HashSet<>();

    // Tasks assigned to this user
    @OneToMany(mappedBy = "assignee", fetch = FetchType.LAZY)
    @Builder.Default
    @ToString.Exclude
    private Set<Task> assignedTasks = new HashSet<>();

    @PrePersist
    protected void onCreate() {
        LocalDateTime now = LocalDateTime.now();
        createdAt = now;
        updatedAt = now;
    }

    @PreUpdate
    protected void onUpdate() {
        updatedAt = LocalDateTime.now();
    }
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/exception"
cat > "src/main/java/com/example/taskmanager/exception/ResourceNotFoundException.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.exception;

/**
 * Thrown when a requested entity (user, project, task) can't be found.
 * Mapped to a 404 by the web layer (not included in this DB/service-focused module).
 */
public class ResourceNotFoundException extends RuntimeException {

    public ResourceNotFoundException(String message) {
        super(message);
    }
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/repository"
cat > "src/main/java/com/example/taskmanager/repository/ProjectRepository.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.repository;

import com.example.taskmanager.entity.Project;
import com.example.taskmanager.entity.ProjectStatus;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;

public interface ProjectRepository extends JpaRepository<Project, Long> {

    List<Project> findByStatus(ProjectStatus status);

    List<Project> findByOwnerId(Long ownerId);

    // Projects a given user belongs to, via the project_members join table.
    @Query("""
           SELECT p FROM Project p
           JOIN p.members m
           WHERE m.user.id = :userId
           """)
    List<Project> findProjectsForMember(@Param("userId") Long userId);

    // Projects with at least one overdue, unfinished task.
    @Query("""
           SELECT DISTINCT p FROM Project p
           JOIN p.tasks t
           WHERE t.dueDate < CURRENT_DATE
             AND t.status <> com.example.taskmanager.entity.TaskStatus.DONE
           """)
    List<Project> findProjectsWithOverdueTasks();
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/repository"
cat > "src/main/java/com/example/taskmanager/repository/TaskRepository.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.repository;

import com.example.taskmanager.entity.Task;
import com.example.taskmanager.entity.TaskPriority;
import com.example.taskmanager.entity.TaskStatus;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.LocalDate;
import java.util.List;

public interface TaskRepository extends JpaRepository<Task, Long> {

    List<Task> findByProjectId(Long projectId);

    List<Task> findByAssigneeId(Long assigneeId);

    List<Task> findByStatus(TaskStatus status);

    List<Task> findByProjectIdAndStatus(Long projectId, TaskStatus status);

    // Tasks due before a given date that aren't finished yet, ordered by priority/due date.
    @Query("""
           SELECT t FROM Task t
           WHERE t.dueDate < :cutoff
             AND t.status <> com.example.taskmanager.entity.TaskStatus.DONE
           ORDER BY t.priority DESC, t.dueDate ASC
           """)
    List<Task> findOverdueTasks(@Param("cutoff") LocalDate cutoff);

    // Count of tasks per status for a given project - useful for a dashboard/kanban view.
    @Query("""
           SELECT t.status AS status, COUNT(t) AS total
           FROM Task t
           WHERE t.project.id = :projectId
           GROUP BY t.status
           """)
    List<TaskStatusCount> countByStatusForProject(@Param("projectId") Long projectId);

    List<Task> findByPriorityAndStatus(TaskPriority priority, TaskStatus status);

    interface TaskStatusCount {
        TaskStatus getStatus();
        Long getTotal();
    }
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/repository"
cat > "src/main/java/com/example/taskmanager/repository/UserRepository.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.repository;

import com.example.taskmanager.entity.User;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.repository.query.Param;

import java.util.Optional;

public interface UserRepository extends JpaRepository<User, Long> {

    Optional<User> findByUsername(String username);

    Optional<User> findByEmail(String email);

    boolean existsByUsername(String username);

    boolean existsByEmail(String email);
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/service"
cat > "src/main/java/com/example/taskmanager/service/ProjectService.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.service;

import com.example.taskmanager.entity.Project;
import com.example.taskmanager.entity.ProjectMember;
import com.example.taskmanager.entity.ProjectStatus;
import com.example.taskmanager.entity.User;
import com.example.taskmanager.exception.ResourceNotFoundException;
import com.example.taskmanager.repository.ProjectRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
public class ProjectService {

    private static final Logger log = LoggerFactory.getLogger(ProjectService.class);

    private final ProjectRepository projectRepository;
    private final UserService userService;

    public ProjectService(ProjectRepository projectRepository, UserService userService) {
        this.projectRepository = projectRepository;
        this.userService = userService;
    }

    @Transactional
    public Project createProject(String name, String description, Long ownerId) {
        log.debug("Creating project '{}' for ownerId={}", name, ownerId);

        User owner = userService.getUserById(ownerId);

        Project project = Project.builder()
                .name(name)
                .description(description)
                .owner(owner)
                .status(ProjectStatus.ACTIVE)
                .build();

        Project saved = projectRepository.save(project);
        log.info("Created project id={} name='{}' owner='{}'", saved.getId(), saved.getName(), owner.getUsername());
        return saved;
    }

    @Transactional(readOnly = true)
    public Project getProjectById(Long id) {
        return projectRepository.findById(id)
                .orElseThrow(() -> {
                    log.error("Project lookup failed: no project with id={}", id);
                    return new ResourceNotFoundException("Project not found: " + id);
                });
    }

    @Transactional(readOnly = true)
    public List<Project> getProjectsForMember(Long userId) {
        List<Project> projects = projectRepository.findProjectsForMember(userId);
        log.debug("Found {} project(s) for userId={}", projects.size(), userId);
        return projects;
    }

    @Transactional
    public Project archiveProject(Long projectId) {
        Project project = getProjectById(projectId);

        if (project.getStatus() == ProjectStatus.ARCHIVED) {
            log.warn("Project id={} is already archived; no-op", projectId);
            return project;
        }

        ProjectStatus previousStatus = project.getStatus();
        project.setStatus(ProjectStatus.ARCHIVED);
        Project saved = projectRepository.save(project);
        log.info("Archived project id={} (previous status={})", saved.getId(), previousStatus);
        return saved;
    }

    @Transactional(readOnly = true)
    public List<Project> getProjectsWithOverdueTasks() {
        List<Project> projects = projectRepository.findProjectsWithOverdueTasks();
        if (!projects.isEmpty()) {
            log.warn("{} project(s) currently have overdue tasks", projects.size());
        }
        return projects;
    }
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/service"
cat > "src/main/java/com/example/taskmanager/service/TaskService.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.service;

import com.example.taskmanager.entity.Project;
import com.example.taskmanager.entity.Task;
import com.example.taskmanager.entity.TaskPriority;
import com.example.taskmanager.entity.TaskStatus;
import com.example.taskmanager.entity.User;
import com.example.taskmanager.exception.ResourceNotFoundException;
import com.example.taskmanager.repository.TaskRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.List;

@Service
public class TaskService {

    private static final Logger log = LoggerFactory.getLogger(TaskService.class);

    private final TaskRepository taskRepository;
    private final ProjectService projectService;
    private final UserService userService;

    public TaskService(TaskRepository taskRepository, ProjectService projectService, UserService userService) {
        this.taskRepository = taskRepository;
        this.projectService = projectService;
        this.userService = userService;
    }

    @Transactional
    public Task createTask(Long projectId, String title, String description, TaskPriority priority, LocalDate dueDate) {
        log.debug("Creating task '{}' for projectId={}", title, projectId);

        Project project = projectService.getProjectById(projectId);

        Task task = Task.builder()
                .project(project)
                .title(title)
                .description(description)
                .priority(priority == null ? TaskPriority.MEDIUM : priority)
                .status(TaskStatus.TODO)
                .dueDate(dueDate)
                .build();

        Task saved = taskRepository.save(task);
        log.info("Created task id={} '{}' in project id={} priority={}",
                saved.getId(), saved.getTitle(), project.getId(), saved.getPriority());
        return saved;
    }

    @Transactional(readOnly = true)
    public Task getTaskById(Long id) {
        return taskRepository.findById(id)
                .orElseThrow(() -> {
                    log.error("Task lookup failed: no task with id={}", id);
                    return new ResourceNotFoundException("Task not found: " + id);
                });
    }

    @Transactional
    public Task assignTask(Long taskId, Long userId) {
        Task task = getTaskById(taskId);
        User assignee = userService.getUserById(userId);

        task.setAssignee(assignee);
        Task saved = taskRepository.save(task);
        log.info("Assigned task id={} to user '{}'", saved.getId(), assignee.getUsername());
        return saved;
    }

    @Transactional
    public Task updateStatus(Long taskId, TaskStatus newStatus) {
        Task task = getTaskById(taskId);
        TaskStatus oldStatus = task.getStatus();

        if (oldStatus == newStatus) {
            log.debug("Task id={} already in status={}; no-op", taskId, newStatus);
            return task;
        }

        task.setStatus(newStatus);
        Task saved = taskRepository.save(task);
        log.info("Task id={} status changed: {} -> {}", saved.getId(), oldStatus, newStatus);

        if (newStatus == TaskStatus.BLOCKED) {
            log.warn("Task id={} '{}' marked BLOCKED", saved.getId(), saved.getTitle());
        }
        return saved;
    }

    @Transactional
    public Task updateTask(Long taskId, Long projectId, String title, String description,
                            TaskPriority priority, LocalDate dueDate, Long assigneeId) {
        Task task = getTaskById(taskId);

        if (!task.getProject().getId().equals(projectId)) {
            Project project = projectService.getProjectById(projectId);
            task.setProject(project);
        }

        task.setTitle(title);
        task.setDescription(description);
        task.setPriority(priority == null ? TaskPriority.MEDIUM : priority);
        task.setDueDate(dueDate);
        task.setAssignee(assigneeId == null ? null : userService.getUserById(assigneeId));

        Task saved = taskRepository.save(task);
        log.info("Updated task id={} '{}'", saved.getId(), saved.getTitle());
        return saved;
    }

    @Transactional
    public void deleteTask(Long taskId) {
        Task task = getTaskById(taskId);
        taskRepository.delete(task);
        log.info("Deleted task id={} '{}'", taskId, task.getTitle());
    }

    @Transactional(readOnly = true)
    public List<Task> getAllTasks() {
        return taskRepository.findAll();
    }

    @Transactional(readOnly = true)
    public List<Task> getOverdueTasks() {
        List<Task> overdue = taskRepository.findOverdueTasks(LocalDate.now());
        if (!overdue.isEmpty()) {
            log.warn("{} task(s) are overdue as of {}", overdue.size(), LocalDate.now());
        }
        return overdue;
    }

    @Transactional(readOnly = true)
    public List<Task> getTasksForProject(Long projectId) {
        return taskRepository.findByProjectId(projectId);
    }
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/service"
cat > "src/main/java/com/example/taskmanager/service/UserService.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.service;

import com.example.taskmanager.entity.User;
import com.example.taskmanager.exception.ResourceNotFoundException;
import com.example.taskmanager.repository.UserRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class UserService {

    private static final Logger log = LoggerFactory.getLogger(UserService.class);

    private final UserRepository userRepository;

    public UserService(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    @Transactional
    public User registerUser(String username, String email, String passwordHash, String fullName) {
        log.debug("Attempting to register user with username='{}', email='{}'", username, email);

        if (userRepository.existsByUsername(username)) {
            log.warn("Registration rejected: username '{}' already taken", username);
            throw new IllegalArgumentException("Username already taken: " + username);
        }
        if (userRepository.existsByEmail(email)) {
            log.warn("Registration rejected: email '{}' already registered", email);
            throw new IllegalArgumentException("Email already registered: " + email);
        }

        User user = User.builder()
                .username(username)
                .email(email)
                .passwordHash(passwordHash)
                .fullName(fullName)
                .build();

        User saved = userRepository.save(user);
        log.info("Registered new user id={} username='{}'", saved.getId(), saved.getUsername());
        return saved;
    }

    @Transactional(readOnly = true)
    public User getUserById(Long id) {
        return userRepository.findById(id)
                .orElseThrow(() -> {
                    log.error("User lookup failed: no user with id={}", id);
                    return new ResourceNotFoundException("User not found: " + id);
                });
    }

    @Transactional(readOnly = true)
    public User getUserByUsername(String username) {
        return userRepository.findByUsername(username)
                .orElseThrow(() -> {
                    log.error("User lookup failed: no user with username='{}'", username);
                    return new ResourceNotFoundException("User not found: " + username);
                });
    }
}
PROJECTFILE_EOF

mkdir -p "src/main/java/com/example/taskmanager/web"
cat > "src/main/java/com/example/taskmanager/web/GlobalExceptionHandler.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.web;

import com.example.taskmanager.dto.ApiErrorResponse;
import com.example.taskmanager.exception.ResourceNotFoundException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import java.util.List;

/**
 * Centralizes exception -> HTTP status mapping so controllers stay free of
 * try/catch blocks and every error response has the same shape (ApiErrorResponse).
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(ResourceNotFoundException.class)
    public ResponseEntity<ApiErrorResponse> handleNotFound(ResourceNotFoundException ex) {
        log.debug("Handled not-found: {}", ex.getMessage());
        return ResponseEntity.status(HttpStatus.NOT_FOUND)
                .body(ApiErrorResponse.of(404, "Not Found", ex.getMessage()));
    }

    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<ApiErrorResponse> handleIllegalArgument(IllegalArgumentException ex) {
        log.debug("Handled bad request: {}", ex.getMessage());
        return ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(ApiErrorResponse.of(400, "Bad Request", ex.getMessage()));
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ApiErrorResponse> handleValidation(MethodArgumentNotValidException ex) {
        List<String> details = ex.getBindingResult().getFieldErrors().stream()
                .map(fe -> fe.getField() + ": " + fe.getDefaultMessage())
                .toList();
        log.debug("Handled validation failure: {}", details);
        return ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(ApiErrorResponse.of(400, "Validation Failed", "One or more fields are invalid", details));
    }

    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<ApiErrorResponse> handleUnreadableBody(HttpMessageNotReadableException ex) {
        log.debug("Handled unreadable request body: {}", ex.getMessage());
        return ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(ApiErrorResponse.of(400, "Bad Request", "Request body is missing or malformed"));
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ApiErrorResponse> handleUnexpected(Exception ex) {
        log.error("Unhandled exception", ex);
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
                .body(ApiErrorResponse.of(500, "Internal Server Error", "Something went wrong"));
    }
}
PROJECTFILE_EOF

mkdir -p "src/main/resources"
cat > "src/main/resources/application.yml" << 'PROJECTFILE_EOF'
spring:
  application:
    name: task-manager

  datasource:
    url: jdbc:postgresql://${DB_HOST:localhost}:${DB_PORT:5432}/${DB_NAME:taskmanager}
    username: ${DB_USER:taskmanager}
    password: ${DB_PASSWORD:taskmanager}
    driver-class-name: org.postgresql.Driver

  jpa:
    # Flyway owns the schema; Hibernate should only validate it matches the entities,
    # never auto-generate or alter tables.
    hibernate:
      ddl-auto: validate
    show-sql: false
    properties:
      hibernate:
        format_sql: true
        jdbc:
          time_zone: UTC
    open-in-view: false

  flyway:
    enabled: true
    locations: classpath:db/migration
    baseline-on-migrate: true
    validate-on-migrate: true

server:
  port: ${SERVER_PORT:8080}

logging:
  level:
    org.flywaydb: INFO
    org.hibernate.SQL: WARN
PROJECTFILE_EOF

mkdir -p "src/main/resources/db/migration"
cat > "src/main/resources/db/migration/V1__create_schema.sql" << 'PROJECTFILE_EOF'
-- V1__create_schema.sql
-- Core schema for the task/project management domain.

CREATE TABLE users (
    id            BIGSERIAL PRIMARY KEY,
    username      VARCHAR(50)  NOT NULL,
    email         VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name     VARCHAR(150) NOT NULL,
    created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_users_username UNIQUE (username),
    CONSTRAINT uq_users_email UNIQUE (email)
);

CREATE TABLE projects (
    id          BIGSERIAL PRIMARY KEY,
    name        VARCHAR(150) NOT NULL,
    description TEXT,
    owner_id    BIGINT       NOT NULL,
    status      VARCHAR(20)  NOT NULL DEFAULT 'ACTIVE',
    created_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_projects_owner FOREIGN KEY (owner_id) REFERENCES users (id) ON DELETE RESTRICT,
    CONSTRAINT chk_projects_status CHECK (status IN ('ACTIVE', 'ARCHIVED', 'COMPLETED'))
);

-- Many-to-many: which users collaborate on which projects
CREATE TABLE project_members (
    project_id BIGINT      NOT NULL,
    user_id    BIGINT      NOT NULL,
    role       VARCHAR(20) NOT NULL DEFAULT 'MEMBER',
    added_at   TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (project_id, user_id),
    CONSTRAINT fk_members_project FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE,
    CONSTRAINT fk_members_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
    CONSTRAINT chk_members_role CHECK (role IN ('OWNER', 'ADMIN', 'MEMBER'))
);

CREATE TABLE tasks (
    id          BIGSERIAL PRIMARY KEY,
    project_id  BIGINT       NOT NULL,
    assignee_id BIGINT,
    title       VARCHAR(200) NOT NULL,
    description TEXT,
    status      VARCHAR(20)  NOT NULL DEFAULT 'TODO',
    priority    VARCHAR(10)  NOT NULL DEFAULT 'MEDIUM',
    due_date    DATE,
    created_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_tasks_project FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE,
    CONSTRAINT fk_tasks_assignee FOREIGN KEY (assignee_id) REFERENCES users (id) ON DELETE SET NULL,
    CONSTRAINT chk_tasks_status CHECK (status IN ('TODO', 'IN_PROGRESS', 'BLOCKED', 'DONE')),
    CONSTRAINT chk_tasks_priority CHECK (priority IN ('LOW', 'MEDIUM', 'HIGH', 'URGENT'))
);

CREATE INDEX idx_projects_owner ON projects (owner_id);
CREATE INDEX idx_tasks_project ON tasks (project_id);
CREATE INDEX idx_tasks_assignee ON tasks (assignee_id);
CREATE INDEX idx_tasks_status ON tasks (status);
CREATE INDEX idx_tasks_due_date ON tasks (due_date);
PROJECTFILE_EOF

mkdir -p "src/main/resources/db/migration"
cat > "src/main/resources/db/migration/V2__seed_data.sql" << 'PROJECTFILE_EOF'
-- V2__seed_data.sql
-- Sample data for local development / demos.
-- Password hashes below are bcrypt hashes of "password123" (dev only, never use in production).

INSERT INTO users (username, email, password_hash, full_name) VALUES
    ('alice',   'alice@example.com',   '$2a$10$7EqJtq98hPqEX7fNZaFWoOhi5UEfIZzxTWzfeM.pxYlOTbtOxJ0Yy', 'Alice Nakamura'),
    ('bob',     'bob@example.com',     '$2a$10$7EqJtq98hPqEX7fNZaFWoOhi5UEfIZzxTWzfeM.pxYlOTbtOxJ0Yy', 'Bob Alonso'),
    ('carol',   'carol@example.com',   '$2a$10$7EqJtq98hPqEX7fNZaFWoOhi5UEfIZzxTWzfeM.pxYlOTbtOxJ0Yy', 'Carol Whitfield'),
    ('dave',    'dave@example.com',    '$2a$10$7EqJtq98hPqEX7fNZaFWoOhi5UEfIZzxTWzfeM.pxYlOTbtOxJ0Yy', 'Dave Okoye');

INSERT INTO projects (name, description, owner_id, status) VALUES
    ('Website Relaunch',   'Redesign and rebuild the public marketing site.', 1, 'ACTIVE'),
    ('Mobile App v2',      'Next major release of the mobile app.',          2, 'ACTIVE'),
    ('Internal Tooling',   'Improve internal developer tooling.',            1, 'COMPLETED');

INSERT INTO project_members (project_id, user_id, role) VALUES
    (1, 1, 'OWNER'),
    (1, 2, 'MEMBER'),
    (1, 3, 'MEMBER'),
    (2, 2, 'OWNER'),
    (2, 3, 'ADMIN'),
    (2, 4, 'MEMBER'),
    (3, 1, 'OWNER'),
    (3, 4, 'MEMBER');

INSERT INTO tasks (project_id, assignee_id, title, description, status, priority, due_date) VALUES
    (1, 2, 'Set up CI/CD pipeline',        'Configure build and deploy pipeline for the new site.', 'IN_PROGRESS', 'HIGH',   '2026-08-10'),
    (1, 3, 'Design homepage mockups',      'Create high-fidelity mockups for the homepage.',         'TODO',        'MEDIUM', '2026-08-05'),
    (1, NULL, 'Write content for About page', 'Draft copy for the About Us page.',                   'TODO',        'LOW',    NULL),
    (2, 3, 'Implement push notifications', 'Add push notification support to the app.',              'IN_PROGRESS', 'URGENT', '2026-08-01'),
    (2, 4, 'Fix login crash on Android 14','Investigate and fix crash reported by beta testers.',     'BLOCKED',     'HIGH',   '2026-07-30'),
    (2, 2, 'Prepare release notes',        'Summarize changes for the v2 release.',                  'TODO',        'MEDIUM', '2026-08-15'),
    (3, 4, 'Migrate build scripts',        'Move build scripts to the new tooling framework.',       'DONE',        'MEDIUM', '2026-07-01');
PROJECTFILE_EOF

mkdir -p "src/main/resources"
cat > "src/main/resources/logback-spring.xml" << 'PROJECTFILE_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>

    <property name="LOG_DIR" value="${LOG_DIR:-logs}"/>
    <property name="LOG_PATTERN"
              value="%d{yyyy-MM-dd HH:mm:ss.SSS} [%thread] %-5level %logger{36} - %msg%n"/>

    <!-- Human-readable console output for local development -->
    <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
        <encoder>
            <pattern>${LOG_PATTERN}</pattern>
        </encoder>
    </appender>

    <!-- Rolling file appender: daily rollover, kept for 14 days, capped at 100MB total -->
    <appender name="FILE" class="ch.qos.logback.core.rolling.RollingFileAppender">
        <file>${LOG_DIR}/task-manager.log</file>
        <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
            <fileNamePattern>${LOG_DIR}/task-manager-%d{yyyy-MM-dd}.%i.log.gz</fileNamePattern>
            <maxFileSize>20MB</maxFileSize>
            <maxHistory>14</maxHistory>
            <totalSizeCap>100MB</totalSizeCap>
        </rollingPolicy>
        <encoder>
            <pattern>${LOG_PATTERN}</pattern>
        </encoder>
    </appender>

    <!-- Dedicated file for WARN/ERROR only, so operational issues are easy to grep for -->
    <appender name="ERROR_FILE" class="ch.qos.logback.core.rolling.RollingFileAppender">
        <file>${LOG_DIR}/task-manager-error.log</file>
        <filter class="ch.qos.logback.classic.filter.ThresholdFilter">
            <level>WARN</level>
        </filter>
        <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
            <fileNamePattern>${LOG_DIR}/task-manager-error-%d{yyyy-MM-dd}.%i.log.gz</fileNamePattern>
            <maxFileSize>20MB</maxFileSize>
            <maxHistory>30</maxHistory>
            <totalSizeCap>100MB</totalSizeCap>
        </rollingPolicy>
        <encoder>
            <pattern>${LOG_PATTERN}</pattern>
        </encoder>
    </appender>

    <!-- Application code: INFO by default, so create/assign/status-change events are visible -->
    <logger name="com.example.taskmanager" level="INFO"/>

    <!-- Quiet down noisy frameworks; bump to DEBUG locally when troubleshooting SQL/tx issues -->
    <logger name="org.hibernate.SQL" level="WARN"/>
    <logger name="org.springframework" level="WARN"/>
    <logger name="org.flywaydb" level="INFO"/>

    <root level="INFO">
        <appender-ref ref="CONSOLE"/>
        <appender-ref ref="FILE"/>
        <appender-ref ref="ERROR_FILE"/>
    </root>

</configuration>
PROJECTFILE_EOF

mkdir -p "src/test/java/com/example/taskmanager/controller"
cat > "src/test/java/com/example/taskmanager/controller/TaskControllerTest.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.controller;

import com.example.taskmanager.dto.TaskStatusUpdateRequest;
import com.example.taskmanager.entity.Project;
import com.example.taskmanager.entity.Task;
import com.example.taskmanager.entity.TaskPriority;
import com.example.taskmanager.entity.TaskStatus;
import com.example.taskmanager.exception.ResourceNotFoundException;
import com.example.taskmanager.service.TaskService;
import com.example.taskmanager.web.GlobalExceptionHandler;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.time.LocalDate;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/**
 * Standalone MockMvc tests (no Spring context) exercising the controller +
 * exception handler together, so both routing and status-code mapping are verified.
 */
@ExtendWith(MockitoExtension.class)
@DisplayName("TaskController")
class TaskControllerTest {

    @Mock
    private TaskService taskService;

    private MockMvc mockMvc;
    private final ObjectMapper objectMapper = new ObjectMapper().registerModule(new JavaTimeModule());

    private Task sampleTask;

    @BeforeEach
    void setUp() {
        TaskController controller = new TaskController(taskService);
        mockMvc = MockMvcBuilders.standaloneSetup(controller)
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();

        Project project = Project.builder().id(1L).name("Website Relaunch").build();
        sampleTask = Task.builder()
                .id(100L)
                .project(project)
                .title("Set up CI/CD pipeline")
                .status(TaskStatus.TODO)
                .priority(TaskPriority.HIGH)
                .dueDate(LocalDate.now().plusDays(5))
                .build();
    }

    @Test
    @DisplayName("POST /api/tasks returns 201 with a Location header on success")
    void createTask_returns201() throws Exception {
        when(taskService.createTask(eq(1L), anyString(), any(), any(), any())).thenReturn(sampleTask);

        String body = """
                {"projectId":1,"title":"Set up CI/CD pipeline","priority":"HIGH","dueDate":"2026-08-10"}
                """;

        mockMvc.perform(post("/api/tasks").contentType("application/json").content(body))
                .andExpect(status().isCreated())
                .andExpect(header().string("Location", "/api/tasks/100"))
                .andExpect(jsonPath("$.title").value("Set up CI/CD pipeline"))
                .andExpect(jsonPath("$.status").value("TODO"));
    }

    @Test
    @DisplayName("POST /api/tasks returns 400 when title is blank")
    void createTask_blankTitle_returns400() throws Exception {
        String body = """
                {"projectId":1,"title":"","priority":"HIGH"}
                """;

        mockMvc.perform(post("/api/tasks").contentType("application/json").content(body))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("Validation Failed"));

        verifyNoInteractions(taskService);
    }

    @Test
    @DisplayName("POST /api/tasks returns 400 when projectId is missing")
    void createTask_missingProjectId_returns400() throws Exception {
        String body = """
                {"title":"Some task","priority":"LOW"}
                """;

        mockMvc.perform(post("/api/tasks").contentType("application/json").content(body))
                .andExpect(status().isBadRequest());

        verifyNoInteractions(taskService);
    }

    @Test
    @DisplayName("GET /api/tasks/{id} returns 200 with the task when found")
    void getTaskById_found_returns200() throws Exception {
        when(taskService.getTaskById(100L)).thenReturn(sampleTask);

        mockMvc.perform(get("/api/tasks/100"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id").value(100))
                .andExpect(jsonPath("$.projectId").value(1));
    }

    @Test
    @DisplayName("GET /api/tasks/{id} returns 404 when the task doesn't exist")
    void getTaskById_notFound_returns404() throws Exception {
        when(taskService.getTaskById(999L)).thenThrow(new ResourceNotFoundException("Task not found: 999"));

        mockMvc.perform(get("/api/tasks/999"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error").value("Not Found"));
    }

    @Test
    @DisplayName("PUT /api/tasks/{id} returns 200 with the updated task")
    void updateTask_returns200() throws Exception {
        when(taskService.updateTask(eq(100L), eq(1L), anyString(), any(), any(), any(), any()))
                .thenReturn(sampleTask);

        String body = """
                {"projectId":1,"title":"Set up CI/CD pipeline","priority":"HIGH"}
                """;

        mockMvc.perform(put("/api/tasks/100").contentType("application/json").content(body))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id").value(100));
    }

    @Test
    @DisplayName("PATCH /api/tasks/{id}/status returns 200 with the new status")
    void updateStatus_returns200() throws Exception {
        Task inProgress = Task.builder()
                .id(100L).project(sampleTask.getProject()).title(sampleTask.getTitle())
                .status(TaskStatus.IN_PROGRESS).priority(TaskPriority.HIGH).build();
        when(taskService.updateStatus(100L, TaskStatus.IN_PROGRESS)).thenReturn(inProgress);

        mockMvc.perform(patch("/api/tasks/100/status")
                        .contentType("application/json")
                        .content(objectMapper.writeValueAsString(new TaskStatusUpdateRequest(TaskStatus.IN_PROGRESS))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("IN_PROGRESS"));
    }

    @Test
    @DisplayName("DELETE /api/tasks/{id} returns 204 on success")
    void deleteTask_returns204() throws Exception {
        doNothing().when(taskService).deleteTask(100L);

        mockMvc.perform(delete("/api/tasks/100"))
                .andExpect(status().isNoContent());

        verify(taskService).deleteTask(100L);
    }

    @Test
    @DisplayName("DELETE /api/tasks/{id} returns 404 when the task doesn't exist")
    void deleteTask_notFound_returns404() throws Exception {
        doThrow(new ResourceNotFoundException("Task not found: 999")).when(taskService).deleteTask(999L);

        mockMvc.perform(delete("/api/tasks/999"))
                .andExpect(status().isNotFound());
    }

    @Test
    @DisplayName("GET /api/tasks returns 200 with a list")
    void getAllTasks_returns200() throws Exception {
        when(taskService.getAllTasks()).thenReturn(java.util.List.of(sampleTask));

        mockMvc.perform(get("/api/tasks"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].id").value(100));
    }
}
PROJECTFILE_EOF

mkdir -p "src/test/java/com/example/taskmanager/service"
cat > "src/test/java/com/example/taskmanager/service/ProjectServiceTest.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.service;

import com.example.taskmanager.entity.Project;
import com.example.taskmanager.entity.ProjectStatus;
import com.example.taskmanager.entity.User;
import com.example.taskmanager.exception.ResourceNotFoundException;
import com.example.taskmanager.repository.ProjectRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@DisplayName("ProjectService")
class ProjectServiceTest {

    @Mock
    private ProjectRepository projectRepository;

    @Mock
    private UserService userService;

    @InjectMocks
    private ProjectService projectService;

    private User owner;
    private Project sampleProject;

    @BeforeEach
    void setUp() {
        owner = User.builder().id(1L).username("alice").build();
        sampleProject = Project.builder()
                .id(10L)
                .name("Website Relaunch")
                .owner(owner)
                .status(ProjectStatus.ACTIVE)
                .build();
    }

    @Test
    @DisplayName("creates a project for an existing owner")
    void createProject_success() {
        when(userService.getUserById(1L)).thenReturn(owner);
        when(projectRepository.save(any(Project.class))).thenReturn(sampleProject);

        Project result = projectService.createProject("Website Relaunch", "desc", 1L);

        assertThat(result.getName()).isEqualTo("Website Relaunch");
        assertThat(result.getStatus()).isEqualTo(ProjectStatus.ACTIVE);
        verify(projectRepository).save(any(Project.class));
    }

    @Test
    @DisplayName("propagates not-found when owner doesn't exist")
    void createProject_ownerMissing() {
        when(userService.getUserById(99L))
                .thenThrow(new ResourceNotFoundException("User not found: 99"));

        assertThatThrownBy(() -> projectService.createProject("X", "desc", 99L))
                .isInstanceOf(ResourceNotFoundException.class);

        verify(projectRepository, never()).save(any());
    }

    @Test
    @DisplayName("throws when project id doesn't exist")
    void getProjectById_notFound() {
        when(projectRepository.findById(404L)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> projectService.getProjectById(404L))
                .isInstanceOf(ResourceNotFoundException.class)
                .hasMessageContaining("404");
    }

    @Test
    @DisplayName("archives an active project")
    void archiveProject_transitionsStatus() {
        when(projectRepository.findById(10L)).thenReturn(Optional.of(sampleProject));
        when(projectRepository.save(any(Project.class))).thenAnswer(inv -> inv.getArgument(0));

        Project result = projectService.archiveProject(10L);

        assertThat(result.getStatus()).isEqualTo(ProjectStatus.ARCHIVED);
        verify(projectRepository).save(sampleProject);
    }

    @Test
    @DisplayName("archiving an already-archived project is a no-op")
    void archiveProject_alreadyArchived_noOp() {
        sampleProject.setStatus(ProjectStatus.ARCHIVED);
        when(projectRepository.findById(10L)).thenReturn(Optional.of(sampleProject));

        Project result = projectService.archiveProject(10L);

        assertThat(result.getStatus()).isEqualTo(ProjectStatus.ARCHIVED);
        verify(projectRepository, never()).save(any());
    }

    @Test
    @DisplayName("delegates member-project lookup to the repository")
    void getProjectsForMember_delegates() {
        when(projectRepository.findProjectsForMember(1L)).thenReturn(List.of(sampleProject));

        List<Project> result = projectService.getProjectsForMember(1L);

        assertThat(result).containsExactly(sampleProject);
    }
}
PROJECTFILE_EOF

mkdir -p "src/test/java/com/example/taskmanager/service"
cat > "src/test/java/com/example/taskmanager/service/TaskServiceTest.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.service;

import com.example.taskmanager.entity.Project;
import com.example.taskmanager.entity.Task;
import com.example.taskmanager.entity.TaskPriority;
import com.example.taskmanager.entity.TaskStatus;
import com.example.taskmanager.entity.User;
import com.example.taskmanager.exception.ResourceNotFoundException;
import com.example.taskmanager.repository.TaskRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.time.LocalDate;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@DisplayName("TaskService")
class TaskServiceTest {

    @Mock
    private TaskRepository taskRepository;

    @Mock
    private ProjectService projectService;

    @Mock
    private UserService userService;

    @InjectMocks
    private TaskService taskService;

    private Project project;
    private User assignee;
    private Task sampleTask;

    @BeforeEach
    void setUp() {
        project = Project.builder().id(1L).name("Website Relaunch").build();
        assignee = User.builder().id(2L).username("bob").build();
        sampleTask = Task.builder()
                .id(100L)
                .project(project)
                .title("Set up CI/CD pipeline")
                .status(TaskStatus.TODO)
                .priority(TaskPriority.HIGH)
                .build();
    }

    @Test
    @DisplayName("creates a task under an existing project, defaulting priority to MEDIUM when unset")
    void createTask_defaultsPriority() {
        when(projectService.getProjectById(1L)).thenReturn(project);
        when(taskRepository.save(any(Task.class))).thenAnswer(inv -> inv.getArgument(0));

        Task result = taskService.createTask(1L, "Write docs", "desc", null, LocalDate.now().plusDays(3));

        assertThat(result.getPriority()).isEqualTo(TaskPriority.MEDIUM);
        assertThat(result.getStatus()).isEqualTo(TaskStatus.TODO);
        verify(taskRepository).save(any(Task.class));
    }

    @Test
    @DisplayName("propagates not-found when the project doesn't exist")
    void createTask_projectMissing() {
        when(projectService.getProjectById(999L))
                .thenThrow(new ResourceNotFoundException("Project not found: 999"));

        assertThatThrownBy(() -> taskService.createTask(999L, "X", "desc", TaskPriority.LOW, null))
                .isInstanceOf(ResourceNotFoundException.class);

        verify(taskRepository, never()).save(any());
    }

    @Test
    @DisplayName("assigns a task to an existing user")
    void assignTask_success() {
        when(taskRepository.findById(100L)).thenReturn(Optional.of(sampleTask));
        when(userService.getUserById(2L)).thenReturn(assignee);
        when(taskRepository.save(any(Task.class))).thenAnswer(inv -> inv.getArgument(0));

        Task result = taskService.assignTask(100L, 2L);

        assertThat(result.getAssignee()).isEqualTo(assignee);
    }

    @Test
    @DisplayName("throws when assigning a task that doesn't exist")
    void assignTask_taskMissing() {
        when(taskRepository.findById(404L)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> taskService.assignTask(404L, 2L))
                .isInstanceOf(ResourceNotFoundException.class);

        verify(userService, never()).getUserById(any());
    }

    @ParameterizedTest(name = "transitions from TODO to {0}")
    @EnumSource(value = TaskStatus.class, names = {"IN_PROGRESS", "BLOCKED", "DONE"})
    @DisplayName("updates task status for valid target statuses")
    void updateStatus_transitions(TaskStatus newStatus) {
        when(taskRepository.findById(100L)).thenReturn(Optional.of(sampleTask));
        when(taskRepository.save(any(Task.class))).thenAnswer(inv -> inv.getArgument(0));

        Task result = taskService.updateStatus(100L, newStatus);

        assertThat(result.getStatus()).isEqualTo(newStatus);
    }

    @Test
    @DisplayName("updating to the same status is a no-op and does not save")
    void updateStatus_sameStatus_noOp() {
        when(taskRepository.findById(100L)).thenReturn(Optional.of(sampleTask));

        Task result = taskService.updateStatus(100L, TaskStatus.TODO);

        assertThat(result.getStatus()).isEqualTo(TaskStatus.TODO);
        verify(taskRepository, never()).save(any());
    }

    @Test
    @DisplayName("returns overdue tasks from the repository")
    void getOverdueTasks_delegates() {
        when(taskRepository.findOverdueTasks(any(LocalDate.class))).thenReturn(List.of(sampleTask));

        List<Task> result = taskService.getOverdueTasks();

        assertThat(result).containsExactly(sampleTask);
    }

    @Test
    @DisplayName("returns an empty list without logging a warning when nothing is overdue")
    void getOverdueTasks_empty() {
        when(taskRepository.findOverdueTasks(any(LocalDate.class))).thenReturn(List.of());

        List<Task> result = taskService.getOverdueTasks();

        assertThat(result).isEmpty();
    }
}
PROJECTFILE_EOF

mkdir -p "src/test/java/com/example/taskmanager/service"
cat > "src/test/java/com/example/taskmanager/service/UserServiceTest.java" << 'PROJECTFILE_EOF'
package com.example.taskmanager.service;

import com.example.taskmanager.entity.User;
import com.example.taskmanager.exception.ResourceNotFoundException;
import com.example.taskmanager.repository.UserRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@DisplayName("UserService")
class UserServiceTest {

    @Mock
    private UserRepository userRepository;

    @InjectMocks
    private UserService userService;

    private User sampleUser;

    @BeforeEach
    void setUp() {
        sampleUser = User.builder()
                .id(1L)
                .username("alice")
                .email("alice@example.com")
                .passwordHash("hashed")
                .fullName("Alice Nakamura")
                .build();
    }

    @Test
    @DisplayName("registers a new user when username and email are both free")
    void registerUser_savesNewUser() {
        when(userRepository.existsByUsername("alice")).thenReturn(false);
        when(userRepository.existsByEmail("alice@example.com")).thenReturn(false);
        when(userRepository.save(any(User.class))).thenReturn(sampleUser);

        User result = userService.registerUser("alice", "alice@example.com", "hashed", "Alice Nakamura");

        assertThat(result.getUsername()).isEqualTo("alice");
        verify(userRepository).save(any(User.class));
    }

    @Test
    @DisplayName("rejects registration when username is already taken")
    void registerUser_rejectsDuplicateUsername() {
        when(userRepository.existsByUsername("alice")).thenReturn(true);

        assertThatThrownBy(() ->
                userService.registerUser("alice", "new@example.com", "hashed", "Someone Else"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("alice");

        verify(userRepository, never()).save(any());
    }

    @Test
    @DisplayName("rejects registration when email is already registered")
    void registerUser_rejectsDuplicateEmail() {
        when(userRepository.existsByUsername("newuser")).thenReturn(false);
        when(userRepository.existsByEmail("alice@example.com")).thenReturn(true);

        assertThatThrownBy(() ->
                userService.registerUser("newuser", "alice@example.com", "hashed", "New User"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("alice@example.com");

        verify(userRepository, never()).save(any());
    }

    @Test
    @DisplayName("returns the user when found by id")
    void getUserById_found() {
        when(userRepository.findById(1L)).thenReturn(Optional.of(sampleUser));

        User result = userService.getUserById(1L);

        assertThat(result).isEqualTo(sampleUser);
    }

    @Test
    @DisplayName("throws ResourceNotFoundException when id doesn't exist")
    void getUserById_notFound() {
        when(userRepository.findById(99L)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> userService.getUserById(99L))
                .isInstanceOf(ResourceNotFoundException.class)
                .hasMessageContaining("99");
    }

    @Test
    @DisplayName("returns the user when found by username")
    void getUserByUsername_found() {
        when(userRepository.findByUsername("alice")).thenReturn(Optional.of(sampleUser));

        User result = userService.getUserByUsername("alice");

        assertThat(result.getId()).isEqualTo(1L);
    }
}
PROJECTFILE_EOF

mkdir -p "src/test/resources"
cat > "src/test/resources/application-test.yml" << 'PROJECTFILE_EOF'
spring:
  datasource:
    url: jdbc:h2:mem:taskmanager;MODE=PostgreSQL;DB_CLOSE_DELAY=-1
    username: sa
    password: ""
    driver-class-name: org.h2.Driver

  jpa:
    hibernate:
      ddl-auto: validate
    show-sql: true

  flyway:
    enabled: true
    locations: classpath:db/migration
    baseline-on-migrate: true

# Run with: mvn test -Dspring.profiles.active=test
# H2's PostgreSQL compatibility mode lets the same Flyway migrations run
# against an in-memory database for fast integration tests.
PROJECTFILE_EOF

mkdir -p "src/test/resources"
cat > "src/test/resources/logback-test.xml" << 'PROJECTFILE_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
        <encoder>
            <pattern>%d{HH:mm:ss.SSS} [%thread] %-5level %logger{36} - %msg%n</pattern>
        </encoder>
    </appender>

    <!-- DEBUG in tests so assertions can be cross-checked against emitted log events -->
    <logger name="com.example.taskmanager" level="DEBUG"/>

    <root level="WARN">
        <appender-ref ref="CONSOLE"/>
    </root>
</configuration>
PROJECTFILE_EOF

cat > .gitignore << 'GITIGNORE_EOF'
target/
*.class
logs/
.idea/
*.iml
.DS_Store
GITIGNORE_EOF

git init -q
git add -A
git commit -q -m "Add Task CRUD REST API: DTOs, validation, controller, exception handling, Postman collection"
git branch -M main
echo "Done. Project created in ./$PROJECT_DIR and git repo initialized on branch main."
echo "Next: cd $PROJECT_DIR && git remote add origin <url> && git push -u origin main"
