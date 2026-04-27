# RICH Detector Event Reconstruction Study

## Data Reconstruction
For this study, 10 runs of COMPASS 2022 W08 were used. The data was recostructed with custom CORAL option files, specifying the ParticlePathFrac paramter (0.1 0.3 0.5 0.7 0.9). The reconstruction on HTCondor was handled by scripts (created with AI) that can be found in `data_reconstruction_scripts/` that exploit Jan Matousek's [BatchJobUtils](https://gitlab.cern.ch/jmatouse/BatchJobUtils). 

The reconstructed data can be found on EOS
`/eos/experiment/compass/scratch/sprazsky/rich_emission_point/`
It is organized in subfolders according to the emission point: `pathfrac01`, `pathfrac03`, etc. In each of the subfolders are stored histo files of the 10 reconstructed runs. 

One of the histo files can be found here:
`/eos/experiment/compass/scratch/sprazsky/rich_emission_point/pathfrac01/run_297678.root`

mDSTs are stored too, but I yet have to organize it, however one can be found for example here: 
`/eos/experiment/compass/scratch/sprazsky/pathfrac_scan/pathfrac01/raws123-0.1/mDST/mDST-297678.root`

## Analysis
A simple ROOT macro `Analysis_SPRec_Like.C` was written (without AI) for analysis of Single Photon Resolution and ratio of pion/kaon ratio. 

## Results
The macro was briefly tested on one run, emission points 0.1 and 0.9. Indeed, one can observe some difference between the maps for the two emission points. 
![Single Photon Resolution and pion/kaon likelihood ratio for emission point 0.1][image_SPRL_01]
![Single Photon Resolution and pion/kaon likelihood ratio for emission point 0.9][image_SPRL_09]

[image_SPRL_01]: img/SPRL_run_297678_pathfrac01.png "Single Photon Resolution & pi/k Likelihood, ParticlePathFr = 0.1"
[image_SPRL_09]: img/SPRL_run_297678_pathfrac09.png "Single Photon Resolution & pi/k Likelihood, ParticlePathFr = 0.9"
