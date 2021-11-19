<:reach:806599358542774292> New Reach Docker images & JavaScript library published <:reach:806599358542774292>
The release candidate for Reach version `{{FINAL_VERSION}}` has received an update.

:squid: New Docker images based on git hash:
`{{GIT_COMMIT_HASH}}`
To update to the newest Docker images:
`reach update`
To check which versions you have:
`reach hashes`

:squid: New node.js package version:
`{{VERSION}}`
To update a node.js project to the newest JavaScript package:
`npm install @reach-sh/stdlib@latest`
To check which version you have:
`npm list @reach-sh/stdlib`

:bulb: Misc tips:
* If you use the Docker images and the node.js package, we recommend that you update them simultaneously.
* If you are noticing old images still running, you can clear them out with
  `reach down`
* If you are noticing old build artifacts still in use, you can clear them out with
  `reach clean`
* If you have any questions or issues, we are happy to answer in #❓help